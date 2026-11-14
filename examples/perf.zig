const std = @import("std");
const zui_raylib = @import("zui_raylib");
const zui = zui_raylib.zui;

/// Why zui_app declared a frame: what ended the host's last wait.
pub const FrameReason = enum {
    first,
    input,
    resize,
    requested,
    timer,
    source,

    pub fn describe(reason: FrameReason) []const u8 {
        return switch (reason) {
            .first => "first frame",
            .input => "input arrived",
            .resize => "window resized",
            .requested => "ui.requestFrame()",
            .timer => "requestFrameAt() came due",
            .source => "a source published",
        };
    }
};

/// What the host measured of each zui frame, kept for the HUD. The HUD
/// shows the frame before the one being declared, since a frame cannot
/// time its own declaration.
pub const Perf = struct {
    pub const history_length = 120;

    pub const Sample = struct {
        begin_frame_us: f32 = 0,
        declare_us: f32 = 0,
        end_frame_us: f32 = 0,
        elements: u32 = 0,
        commands: u32 = 0,
        measure_calls: u32 = 0,
        reason: FrameReason = .first,

        pub fn totalMicroseconds(sample: Sample) f32 {
            return sample.begin_frame_us + sample.declare_us + sample.end_frame_us;
        }
    };

    history: [history_length]Sample = @splat(.{}),
    newest: usize = history_length - 1,
    recorded: usize = 0,

    zui_frames: u64 = 0,
    /// Frames declared in the last whole second of the clock.
    frames_last_second: u32 = 0,
    frames_this_second: u32 = 0,
    this_second: u64 = 0,
    submit_us: f32 = 0,
    measure_calls_total: u64 = 0,
    wakes: u32 = 0,
    dropped_input_events: u32 = 0,
    diagnostics: zui.Diagnostics = .{},
    next_frame: zui.NextFrame = .immediately,
    next_frame_seconds: f32 = 0,

    pub fn record(self: *Perf, sample: Sample) void {
        self.newest = (self.newest + 1) % history_length;
        self.history[self.newest] = sample;
        self.recorded = @min(self.recorded + 1, history_length);
    }

    /// Counts a frame declared at `seconds` into the second it falls in.
    pub fn countFrameAt(self: *Perf, seconds: f64) void {
        const second: u64 = @intFromFloat(@max(0, @floor(seconds)));
        if (second != self.this_second) {
            self.frames_last_second = if (second == self.this_second + 1) self.frames_this_second else 0;
            self.frames_this_second = 0;
            self.this_second = second;
        }
        self.frames_this_second += 1;
    }

    pub fn latest(self: *const Perf) Sample {
        return self.history[self.newest];
    }

    /// Oldest first, `history_length` long; unrecorded samples are zero.
    pub fn sampleAt(self: *const Perf, age_from_oldest: usize) Sample {
        return self.history[(self.newest + 1 + age_from_oldest) % history_length];
    }

    pub const Summary = struct { minimum: f32, average: f32, p95: f32, maximum: f32 };

    pub fn summarize(self: *const Perf) Summary {
        if (self.recorded == 0) return .{ .minimum = 0, .average = 0, .p95 = 0, .maximum = 0 };
        var totals: [history_length]f32 = undefined;
        var sum: f32 = 0;
        for (0..self.recorded) |age| {
            const total = self.history[(self.newest + history_length - age) % history_length].totalMicroseconds();
            totals[age] = total;
            sum += total;
        }
        const recorded_totals = totals[0..self.recorded];
        std.mem.sort(f32, recorded_totals, {}, std.sort.asc(f32));
        const p95_index = (self.recorded * 95) / 100;
        return .{
            .minimum = recorded_totals[0],
            .average = sum / @as(f32, @floatFromInt(self.recorded)),
            .p95 = recorded_totals[@min(p95_index, self.recorded - 1)],
            .maximum = recorded_totals[self.recorded - 1],
        };
    }
};

/// zui_raylib's renderer, timing each submit for the performance strip.
/// It is also the tour's text contract, as the renderer it wraps is.
pub const TimedRenderer = struct {
    pub const zui_surfaces = zui_raylib.Renderer.zui_surfaces;
    pub const ImageHandle = zui_raylib.Renderer.ImageHandle;

    raylib: zui_raylib.Renderer = .{},
    /// Set by the application, which has the `Io`; until then submits are not timed.
    io: ?std.Io = null,
    last_submit: Submitted = .{},

    pub const Submitted = struct {
        started_at: zui.Instant = .zero,
        ended_at: zui.Instant = .zero,
        elements: u32 = 0,
        commands: u32 = 0,
        diagnostics: zui.Diagnostics = .{},
    };

    pub fn zuiMeasure(self: *TimedRenderer, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return self.raylib.zuiMeasure(run, key);
    }

    pub fn zuiSubmit(self: *TimedRenderer, surface: zui.Surface, frame: anytype) !void {
        const io = self.io orelse return self.raylib.zuiSubmit(surface, frame);
        const started_at: zui.Instant = .fromTimestamp(std.Io.Timestamp.now(io, .awake));
        try self.raylib.zuiSubmit(surface, frame);
        self.last_submit = .{
            .started_at = started_at,
            .ended_at = .fromTimestamp(std.Io.Timestamp.now(io, .awake)),
            .elements = frame.elementCount(),
            .commands = @intCast(frame.commands().len),
            .diagnostics = frame.diagnostics,
        };
    }
};
