//! The zui tour, run by `zui_app` on raylib's window.
//!
//! ```sh
//! zig build demo                                     # interactive window
//! zig build demo -- --screen box_storm               # start on one screen
//! zig build demo -- --frames 900 --cycle 40          # visit every screen, 40 frames each, then quit
//! zig build demo -- --screenshot tour.png --screen gallery  # render offscreen, save a PNG and quit
//! zig build demo -- --measure-idle                   # report the CPU time used over 10 idle seconds
//! zig build demo -- --measure-startup                # report the time from process start to the first presented frame
//! ```

const std = @import("std");
const zui_raylib = @import("zui_raylib");
const kit = @import("kit.zig");
const zui = kit.zui;
const zui_app = kit.zui_app;
const Ui = kit.Ui;
const Tour = @import("app.zig").App;
const FrameReason = @import("perf.zig").FrameReason;

pub fn main(init: std.process.Init) !void {
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    try zui_app.run(TourOnRaylib, init, .{ .title = "zui tour (raylib)", .size = default_window_size, .visible = !options.hidden, .resizable = !options.hidden });
}

const default_window_size: [2]u32 = .{ 1440, 900 };

/// Frames drawn before a screenshot, in live mode, so it shows a settled
/// layout and the gallery's first tiles.
const screenshot_after_frames = 45;

/// The tour's application, as `zui_app` runs one: this loads its fonts
/// into the renderer, times each step for the performance strip, and
/// passes each step on.
const TourOnRaylib = struct {
    pub const Host = zui_raylib.Host;
    pub const Renderer = kit.Renderer;

    tour: Tour,
    sources: *kit.Sources,
    host: *Host,
    renderer: *Renderer,
    fonts: kit.Fonts,
    options: Options,
    frames: u64 = 0,
    next: zui.NextFrame = .immediately,
    previous_params: ?zui.FrameParams = null,
    reason: FrameReason = .first,
    polled_at: zui.Instant = .zero,
    declare_started_at: zui.Instant = .zero,
    declared_at: zui.Instant = .zero,
    measure_calls_seen: u64 = 0,
    idle_measurement: ?IdleMeasurement = null,

    pub fn init(app: *TourOnRaylib, start: zui_app.Start(TourOnRaylib)) !void {
        const process = start.process orelse return error.NoProcessArguments;
        const options = try parseOptions(try process.minimal.args.toSlice(process.arena.allocator()));
        app.* = .{
            .tour = undefined,
            .sources = &app.tour.sources,
            .host = start.host,
            .renderer = start.renderer,
            .fonts = try .load(),
            .options = options,
            .idle_measurement = if (options.measure_idle) .{ .launched_at = start.host.now() } else null,
        };
        start.renderer.raylib.fonts = &app.fonts.loaded;
        start.renderer.io = start.io;
        app.tour.init(start.io, start.host.now());
        app.tour.host_waker = start.waker;
        if (options.screen) |screen| app.tour.current = screen;
        app.tour.cycle_every = options.cycle_every;
        if (options.measure_idle) app.tour.heartbeat = false;
        if (options.screenshot_path != null) {
            app.tour.live = true;
            start.host.drawOffscreen();
        }
    }

    /// Stops the tour's producers, so the sources outlive them.
    pub fn deinit(app: *TourOnRaylib) void {
        app.tour.deinit();
        app.fonts.deinit();
        if (app.options.frame_limit != null) std.debug.print("drew {d} frames, diagnostics ok: {}\n", .{ app.frames, app.tour.perf.diagnostics.ok() });
    }

    pub fn zuiRecord(app: *TourOnRaylib, record: *zui.RecordBuilder) void {
        // The host measured the viewport at the zoom of the record before,
        // and the tour may have zoomed since.
        const polled_zoom = record.params.zoom;
        record.params.zoom = app.tour.zoom;
        record.params.viewport = .{ record.params.viewport[0] * polled_zoom / app.tour.zoom, record.params.viewport[1] * polled_zoom / app.tour.zoom };
        for (app.tour.environment_changes.drain()) |change| record.append(.{ .environment = change });
        app.tour.perf.dropped_input_events +|= record.dropped_events;
        app.reason = app.frameReason(record);
        app.previous_params = record.params;
        app.polled_at = app.host.now();
    }

    pub fn zuiDeclare(app: *TourOnRaylib, ui: *Ui) void {
        if (app.idle_measurement) |*measurement| {
            if (measurement.reportAt(ui.now(), app)) |report| {
                std.debug.print("{f}\n", .{report});
                app.host.close();
            } else {
                ui.requestFrameAt(measurement.nextCheckpoint());
            }
        }
        if (app.options.measure_startup) {
            if (app.frames == 1) {
                reportStartup(app.host);
                app.host.close();
            }
            ui.requestFrame();
        }
        app.declare_started_at = app.host.now();
        app.tour.declare(ui);
        app.declared_at = app.host.now();
        app.host.clear_color = kit.Palette.forEnvironment(ui.environment()).background;
    }

    /// After each frame: records what it cost, runs the tour's loaders,
    /// and takes the screenshot once the tour has settled.
    pub fn zuiLoader(app: *TourOnRaylib, ui: *const Ui, _: std.Io) void {
        app.recordPerf(ui);
        app.tour.afterFrame(ui);
        kit.zui_tracy.frameMark();

        app.frames += 1;
        if (app.options.screenshot_path) |path| if (app.frames == screenshot_after_frames) {
            app.host.saveScreenshot(path) catch |err| {
                std.debug.print("could not save {s}: {t}\n", .{ path, err });
                std.process.exit(1);
            };
            std.debug.print("saved {s}\n", .{path});
            app.host.close();
        };
        if (app.options.frame_limit) |limit| if (app.frames == limit) app.host.close();

        app.next = ui.nextFrame(app.sources);
        const perf = &app.tour.perf;
        perf.next_frame = app.next;
        perf.next_frame_seconds = switch (app.next) {
            .at => |deadline| deadline.secondsSince(ui.now()),
            else => 0,
        };
    }

    /// What ended the host's wait for this frame.
    fn frameReason(app: *const TourOnRaylib, record: *const zui.RecordBuilder) FrameReason {
        const previous = app.previous_params orelse return .first;
        if (record.events().len != 0) return .input;
        const params = record.params;
        if (!std.meta.eql(params.viewport, previous.viewport) or params.scale != previous.scale or params.zoom != previous.zoom) return .resize;
        if (sourcesPending(app.sources)) return .source;
        return switch (app.next) {
            .immediately => .requested,
            .at => .timer,
            // GLFW ended the wait for input that made no event of zui's.
            .on_event => .input,
        };
    }

    fn recordPerf(app: *TourOnRaylib, ui: *const Ui) void {
        const submitted = app.renderer.last_submit;
        const perf = &app.tour.perf;
        const measure_calls = ui.measureCalls() - app.measure_calls_seen;
        app.measure_calls_seen = ui.measureCalls();
        perf.record(.{
            .begin_frame_us = microsecondsBetween(app.polled_at, app.declare_started_at),
            .declare_us = microsecondsBetween(app.declare_started_at, app.declared_at),
            .end_frame_us = microsecondsBetween(app.declared_at, submitted.started_at),
            .elements = submitted.elements,
            .commands = submitted.commands,
            .measure_calls = @intCast(measure_calls),
            .reason = app.reason,
        });
        perf.zui_frames += 1;
        perf.countFrameAt(ui.now().secondsSince(app.tour.started_at));
        perf.measure_calls_total += measure_calls;
        perf.submit_us = microsecondsBetween(submitted.started_at, submitted.ended_at);
        perf.diagnostics = submitted.diagnostics;
        perf.wakes = app.tour.wakes.load(.monotonic);
    }
};

fn sourcesPending(sources: *const kit.Sources) bool {
    inline for (@typeInfo(kit.Sources).@"struct".fields) |field| {
        if (@field(sources, field.name).zuiPending()) return true;
    }
    return false;
}

fn microsecondsBetween(earlier: zui.Instant, later: zui.Instant) f32 {
    return later.secondsSince(earlier) * std.time.us_per_s;
}

const Options = struct {
    screen: ?kit.Screen = null,
    frame_limit: ?u64 = null,
    cycle_every: ?u32 = null,
    screenshot_path: ?[:0]const u8 = null,
    hidden: bool = false,
    measure_idle: bool = false,
    measure_startup: bool = false,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, argument, "--screen") and has_value) {
            index += 1;
            options.screen = try parseScreen(arguments[index]);
        } else if (std.mem.eql(u8, argument, "--frames") and has_value) {
            index += 1;
            options.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
        } else if (std.mem.eql(u8, argument, "--cycle") and has_value) {
            index += 1;
            options.cycle_every = try std.fmt.parseInt(u32, arguments[index], 10);
        } else if (std.mem.eql(u8, argument, "--screenshot") and has_value) {
            index += 1;
            options.screenshot_path = arguments[index];
            options.hidden = true;
        } else if (std.mem.eql(u8, argument, "--hidden")) {
            options.hidden = true;
        } else if (std.mem.eql(u8, argument, "--measure-idle")) {
            options.hidden = true;
            options.measure_idle = true;
        } else if (std.mem.eql(u8, argument, "--measure-startup")) {
            options.hidden = true;
            options.measure_startup = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --screen <name>, --frames <count>, --cycle <frames>, --screenshot <path>, --hidden, --measure-idle or --measure-startup\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn parseScreen(name: []const u8) !kit.Screen {
    return std.meta.stringToEnum(kit.Screen, name) orelse {
        std.debug.print("unknown screen \"{s}\"; expected one of:", .{name});
        for (std.meta.fieldNames(kit.Screen)) |screen_name| std.debug.print(" {s}", .{screen_name});
        std.debug.print("\n", .{});
        return error.UnknownScreen;
    };
}

/// `--measure-idle`: the CPU time the tour uses while idle, read by the
/// process itself at two frames it asks for with `requestFrameAt`, so the
/// run ends on its own and needs no outside sampler.
const IdleMeasurement = struct {
    const warm_up_seconds = 5;
    const measured_seconds = 10;

    launched_at: zui.Instant,
    start: ?Checkpoint = null,

    const Checkpoint = struct { at: zui.Instant, cpu_nanoseconds: u64, frames: u64, wakes: u32 };

    const Report = struct {
        cpu_nanoseconds: u64,
        seconds: f32,
        frames: u64,
        wakes: u32,

        pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("idle: {d:.1} ms of CPU over {d:.1} s ({d:.3}% of one core), {d} frames, {d} wakes", .{
                @as(f64, @floatFromInt(self.cpu_nanoseconds)) / std.time.ns_per_ms,
                self.seconds,
                @as(f64, @floatFromInt(self.cpu_nanoseconds)) / (self.seconds * std.time.ns_per_s) * 100,
                self.frames,
                self.wakes,
            });
        }
    };

    fn nextCheckpoint(self: *const IdleMeasurement) zui.Instant {
        if (self.start) |start| return start.at.addSeconds(measured_seconds);
        return self.launched_at.addSeconds(warm_up_seconds);
    }

    /// Called in every frame; the frame at the end of the measurement
    /// counts toward it.
    fn reportAt(self: *IdleMeasurement, at: zui.Instant, app: *const TourOnRaylib) ?Report {
        if (at.isBefore(self.nextCheckpoint())) return null;
        const checkpoint: Checkpoint = .{ .at = at, .cpu_nanoseconds = processCpuNanoseconds(), .frames = app.frames, .wakes = app.tour.wakes.load(.monotonic) };
        const start = self.start orelse {
            self.start = checkpoint;
            return null;
        };
        return .{
            .cpu_nanoseconds = checkpoint.cpu_nanoseconds - start.cpu_nanoseconds,
            .seconds = checkpoint.at.secondsSince(start.at),
            .frames = checkpoint.frames - start.frames,
            .wakes = checkpoint.wakes - start.wakes,
        };
    }
};

const windows = std.os.windows;
extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *windows.FILETIME, exit: *windows.FILETIME, kernel: *windows.FILETIME, user: *windows.FILETIME) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(time: *windows.FILETIME) callconv(.winapi) void;

/// In 100-nanosecond ticks; creation since 1601, the others in total.
const ProcessTimes = struct { creation: u64, kernel: u64, user: u64 };

fn processTimes() ProcessTimes {
    var times: [4]windows.FILETIME = undefined;
    if (GetProcessTimes(windows.GetCurrentProcess(), &times[0], &times[1], &times[2], &times[3]) == .FALSE) return .{ .creation = 0, .kernel = 0, .user = 0 };
    return .{ .creation = fileTimeTicks(times[0]), .kernel = fileTimeTicks(times[2]), .user = fileTimeTicks(times[3]) };
}

/// User and kernel time of every thread of this process.
fn processCpuNanoseconds() u64 {
    if (@import("builtin").os.tag == .windows) {
        const times = processTimes();
        return (times.kernel + times.user) * 100;
    }
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return timevalNanoseconds(usage.utime) + timevalNanoseconds(usage.stime);
}

/// `--measure-startup`: from the moment the OS created the process to the
/// moment the first frame was presented, read in the second frame.
fn reportStartup(host: *const TourOnRaylib.Host) void {
    const presented = host.first_present orelse return std.debug.print("startup: no frame was presented\n", .{});
    if (@import("builtin").os.tag != .windows) return std.debug.print("startup: not measured on this system\n", .{});
    var wall_now: windows.FILETIME = undefined;
    GetSystemTimePreciseAsFileTime(&wall_now);
    const since_creation_ns = (fileTimeTicks(wall_now) - processTimes().creation) * 100;
    const created = host.now().nanoseconds -| since_creation_ns;
    std.debug.print("startup: first frame presented {d:.1} ms after the process was created; the window was open at {d:.1} ms\n", .{
        milliseconds(presented.nanoseconds -| created),
        milliseconds(host.opened_at.nanoseconds -| created),
    });
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn fileTimeTicks(time: windows.FILETIME) u64 {
    return @as(u64, time.dwHighDateTime) << 32 | time.dwLowDateTime;
}

fn timevalNanoseconds(time: anytype) u64 {
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.usec)) * std.time.ns_per_us;
}
