//! The demo's thumbnail loads: a `zui_async.KeyedLoads` source the grid
//! reads, and a loader that starts what the grid asked for on the
//! application's `Io`, so nothing on the UI thread waits for a load.

const std = @import("std");
const Io = std.Io;
const zui = @import("zui");
const zui_async = @import("zui_async");

/// A thumbnail as a 4×4 grid of colors.
pub const Thumbnail = struct { colors: [4][4]zui.Color };

pub const LoadError = error{
    /// Demand lapsed, or the application is shutting down.
    Canceled,
    /// The `Io` could not run the load on a thread of its own, and running it
    /// inline would block the UI thread.
    NoThreadAvailable,
};

pub const count = 600;

/// One slot per thumbnail, so no key the grid asks for is ever refused.
pub const Loads = zui_async.KeyedLoads(u32, LoadError!Thumbnail, .{ .capacity = count });

/// How long a simulated load takes, chosen per key.
pub const Delay = struct {
    min_milliseconds: u32 = 200,
    max_milliseconds: u32 = 800,

    pub const none: Delay = .{ .min_milliseconds = 0, .max_milliseconds = 0 };
};

/// Starts each load the grid asked for as its own task, and counts what
/// happened to them for the grid's header.
pub const Loader = struct {
    io: Io,
    delay: Delay = .{},
    tasks: Io.Group = .init,
    /// Read and written on the UI thread only.
    started: u32 = 0,
    completed: std.atomic.Value(u32) = .init(0),
    canceled: std.atomic.Value(u32) = .init(0),

    /// Runs after `endFrame`, so it sees the keys the frame asked for.
    pub fn startWanted(self: *Loader, loads: *Loads, waker: zui.Waker) void {
        var to_start = loads.toStart(waker);
        while (to_start.next()) |load| {
            self.started += 1;
            self.tasks.concurrent(self.io, run, .{ self, load }) catch load.finish(error.NoThreadAvailable);
        }
    }

    /// Cancels the loads still running and waits for them, so the source
    /// outlives its producers. Call before freeing the source.
    pub fn deinit(self: *Loader) void {
        self.tasks.cancel(self.io);
    }

    fn run(self: *Loader, load: Loads.Load) void {
        const result = produce(self.io, load, self.delay);
        if (result) |_| {
            _ = self.completed.fetchAdd(1, .monotonic);
        } else |err| switch (err) {
            error.Canceled => _ = self.canceled.fetchAdd(1, .monotonic),
            error.NoThreadAvailable => {},
        }
        load.finish(result);
    }
};

/// A slow "load": a sleep that stops early once demand lapses, then colors
/// derived from the key.
fn produce(io: Io, load: Loads.Load, delay: Delay) LoadError!Thumbnail {
    var prng: std.Random.DefaultPrng = .init(@as(u64, load.key) *% 0x9E3779B97F4A7C15);
    const random = prng.random();
    var remaining_milliseconds = random.intRangeAtMost(u32, delay.min_milliseconds, delay.max_milliseconds);
    const abandon_check_milliseconds = 20;
    while (remaining_milliseconds > 0) {
        if (load.abandoned()) return error.Canceled;
        const step = @min(remaining_milliseconds, abandon_check_milliseconds);
        try io.sleep(.fromMilliseconds(step), .awake);
        remaining_milliseconds -= step;
    }
    var thumbnail: Thumbnail = undefined;
    const base_hue = random.int(u8);
    for (&thumbnail.colors, 0..) |*row, row_index| for (row, 0..) |*color, column_index| {
        const shade: u8 = @intCast(40 + (row_index + column_index) * 20);
        color.* = .{ .r = base_hue, .g = shade, .b = 255 - base_hue / 2 };
    };
    return thumbnail;
}

const testing = std.testing;
const zui_testing = @import("zui_testing");

const TestSources = struct { thumbnails: Loads = .{} };
const TestUi = zui.Context(.{ .Text = zui_testing.FixedMetricsText(u16), .Sources = TestSources });

const WakeCounter = struct {
    wakes: std.atomic.Value(u32) = .init(0),

    fn waker(self: *WakeCounter) zui.Waker {
        return .{ .context = self, .wakeFn = countWake };
    }

    fn countWake(context: *anyopaque) void {
        const self: *WakeCounter = @ptrCast(@alignCast(context));
        _ = self.wakes.fetchAdd(1, .monotonic);
    }
};

/// Declares a grid asking for the first `wanted` thumbnails, and counts
/// those ready.
fn declareGrid(ui: *TestUi, wanted: u32) u32 {
    const thumbnails = ui.source(.thumbnails);
    var ready: u32 = 0;
    for (0..wanted) |key| {
        if (thumbnails.get(@intCast(key)) == .ready) ready += 1;
    }
    return ready;
}

fn frame(ui: *TestUi, sources: *TestSources, number: u64, wanted: u32) u32 {
    ui.beginFrame(&.{ .params = .{ .now = .fromNanoseconds(number * std.time.ns_per_s / 60), .viewport = .{ 800, 600 } } }, sources);
    const ready = declareGrid(ui, wanted);
    ui.release(ui.endFrame());
    return ready;
}

test "100 loads finishing between two frames cause one wake" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: TestUi = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    const sources = try testing.allocator.create(TestSources);
    defer testing.allocator.destroy(sources);
    sources.* = .{};
    var wake_counter: WakeCounter = .{};
    var loader: Loader = .{ .io = testing.io, .delay = .none };
    defer loader.deinit();

    try testing.expectEqual(@as(u32, 0), frame(&ui, sources, 0, 100));
    loader.startWanted(&sources.thumbnails, wake_counter.waker());
    try testing.expectEqual(@as(u32, 100), loader.started);
    try loader.tasks.await(testing.io);

    try testing.expectEqual(@as(u32, 100), loader.completed.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), wake_counter.wakes.load(.monotonic));
    try testing.expectEqual(zui.NextFrame.immediately, ui.nextFrame(sources));
    try testing.expectEqual(@as(u32, 100), frame(&ui, sources, 1, 100));
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame(sources));
}

test "the grid never waits for a load, and unread loads are abandoned" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: TestUi = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    const sources = try testing.allocator.create(TestSources);
    defer testing.allocator.destroy(sources);
    sources.* = .{};
    var wake_counter: WakeCounter = .{};
    var loader: Loader = .{ .io = testing.io, .delay = .{ .min_milliseconds = 10_000, .max_milliseconds = 10_000 } };
    defer loader.deinit();

    try testing.expectEqual(@as(u32, 0), frame(&ui, sources, 0, 8));
    loader.startWanted(&sources.thumbnails, wake_counter.waker());
    var number: u64 = 1;
    while (number <= 40) : (number += 1) try testing.expectEqual(@as(u32, 0), frame(&ui, sources, number, 0));
    try loader.tasks.await(testing.io);
    try testing.expectEqual(@as(u32, 8), loader.canceled.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), loader.completed.load(.monotonic));
}
