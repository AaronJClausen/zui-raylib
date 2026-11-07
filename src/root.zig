//! zui-raylib: renders zui frames with raylib and turns raylib's input into
//! frame records. See README.md for usage.

const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const zui_async = @import("zui_async");
pub const zui_tracy = @import("zui_tracy");

/// The raw raylib bindings, translated from raylib.h.
pub const c = @import("raylib");

pub const Texture = c.Texture2D;

/// Compiled into raylib with its desktop GLFW platform (the default);
/// raylib itself exposes no way to wake its event wait from another thread.
extern fn glfwPostEmptyEvent() void;

/// A `zui.Config` for `Renderer`: text measured by `Text`, images that are
/// raylib textures, and exactly the commands `Renderer` draws. Override
/// any other field:
/// `zui.Context(zui_raylib.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.Text = Text;
    result.commands = .initEmpty();
    result.ImageHandle = Renderer.ImageHandle;
    result.CustomData = void;
    result.MaterialHandle = void;
    return result;
}

/// The text contract, through raylib fonts. `FontId` indexes `fonts`; with
/// no fonts loaded, raylib's built-in font is used for every id.
pub const Text = struct {
    fonts: []const c.Font = &.{},
    /// Space raylib's fonts need between glyphs, as a fraction of the size,
    /// before the style's own letter spacing. raylib's `DrawText` uses 0.1.
    font_spacing: f32 = 0.1,

    /// Each glyph counts its advance plus the spacing after it, so that
    /// measuring "a", " " and "b" separately adds up to measuring "a b",
    /// which zui relies on when it wraps. raylib's `MeasureTextEx` leaves
    /// out the spacing after the last glyph.
    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        const raylib_font = self.fontFor(key.font);
        const glyph_spacing = self.spacing(key.size, key.letter_spacing);
        var width: f32 = 0;
        var height: f32 = key.size;
        var chunks: CStringChunks = .init(run);
        while (chunks.next()) |chunk| {
            const measured = c.MeasureTextEx(raylib_font, chunk.ptr, key.size, glyph_spacing);
            width += measured.x + glyph_spacing;
            height = @max(height, measured.y);
        }
        return .{ width, height };
    }

    pub fn fontFor(self: *const Text, font: u16) c.Font {
        return if (font < self.fonts.len) self.fonts[font] else c.GetFontDefault();
    }

    /// raylib's spacing between glyphs for text of `size` with the style's
    /// `letter_spacing`.
    pub fn spacing(self: *const Text, size: f32, letter_spacing: f32) f32 {
        return size * self.font_spacing + letter_spacing;
    }
};

/// raylib takes NUL-terminated strings, and zui hands out slices into its
/// frame buffer, so text is copied into this buffer one chunk at a time.
const CStringChunks = struct {
    const capacity = 1024;

    remaining: []const u8,
    buffer: [capacity + 1]u8 = undefined,

    fn init(text: []const u8) CStringChunks {
        return .{ .remaining = text };
    }

    /// The next chunk, split on a UTF-8 boundary so no code point is cut.
    fn next(self: *CStringChunks) ?[:0]const u8 {
        if (self.remaining.len == 0) return null;
        var length = @min(self.remaining.len, capacity);
        while (length < self.remaining.len and length > 0 and (self.remaining[length] & 0xC0) == 0x80) length -= 1;
        if (length == 0) length = @min(self.remaining.len, capacity);
        @memcpy(self.buffer[0..length], self.remaining[0..length]);
        self.buffer[length] = 0;
        self.remaining = self.remaining[length..];
        return self.buffer[0..length :0];
    }
};

// =====================================================================
// The host side: input, waking, waiting and requests
// =====================================================================

/// The host's monotonic clock, for frame records.
pub fn now(io: std.Io) zui.Instant {
    return .fromTimestamp(std.Io.Timestamp.now(io, .awake));
}

/// The viewport and scale of raylib's window, for frame records.
pub fn windowParams(at: zui.Instant) zui.FrameParams {
    const screen_width = c.GetScreenWidth();
    return .{
        .now = at,
        .viewport = .{ @floatFromInt(screen_width), @floatFromInt(c.GetScreenHeight()) },
        .scale = if (screen_width > 0) @as(f32, @floatFromInt(c.GetRenderWidth())) / @as(f32, @floatFromInt(screen_width)) else 1,
    };
}

/// Ends raylib's event wait from any thread. GLFW documents
/// `glfwPostEmptyEvent` as callable from any thread, and the empty event
/// stays queued until the next wait, so the wake is sticky.
pub fn wake() void {
    glfwPostEmptyEvent();
}

/// A `zui.Waker` for sources' producers, calling `wake`.
pub fn waker() zui.Waker {
    return .{ .context = &waker_context, .wakeFn = wakeErased };
}

var waker_context: u8 = 0;

fn wakeErased(_: *anyopaque) void {
    wake();
}

/// Sleeps as `zui.NextFrame` says, inside raylib's `EndDrawing`, which waits
/// for events after presenting when event waiting is on. A deadline is met
/// by a timer that wakes the wait at that instant.
///
/// ```zig
/// pacer.prepare(ui.nextFrame(&app.sources)); // after the loader
/// c.EndDrawing();
/// ```
pub const FramePacer = struct {
    io: std.Io,
    timers: std.Io.Group = .init,
    scheduled_deadline: ?zui.Instant = null,

    /// Call after the loader and before `EndDrawing`, so a producer's wake
    /// after `nextFrame` stays queued for the wait.
    pub fn prepare(self: *FramePacer, next: zui.NextFrame) void {
        switch (next) {
            .immediately => c.DisableEventWaiting(),
            .on_event => c.EnableEventWaiting(),
            .at => |deadline| {
                c.EnableEventWaiting();
                if (self.scheduled_deadline) |scheduled| if (scheduled.nanoseconds == deadline.nanoseconds) return;
                self.scheduled_deadline = deadline;
                self.timers.concurrent(self.io, wakeAt, .{ self.io, deadline }) catch c.DisableEventWaiting();
            },
        }
    }

    /// Stops the timers. Call before closing the window.
    pub fn deinit(self: *FramePacer) void {
        self.timers.cancel(self.io);
    }

    /// A sleep may end a little early, and a frame woken before its
    /// deadline would ask for the same instant again, which `prepare` does
    /// not schedule twice, so this wakes only once the deadline has passed.
    fn wakeAt(io: std.Io, deadline: zui.Instant) std.Io.Cancelable!void {
        while (now(io).isBefore(deadline)) {
            const remaining = deadline.nanoseconds -| now(io).nanoseconds;
            try io.sleep(.fromNanoseconds(@intCast(remaining)), .awake);
        }
        wake();
    }
};

/// Applies what a frame asks of the host that raylib can do: the cursor.
/// raylib has no IME window to place.
pub const HostRequestApplier = struct {
    applied_cursor: ?zui.Cursor = null,

    pub fn apply(self: *HostRequestApplier, requests: zui.HostRequests) void {
        if (self.applied_cursor == requests.cursor) return;
        self.applied_cursor = requests.cursor;
        c.SetMouseCursor(mouseCursorFor(requests.cursor));
    }
};

/// The nearest of raylib's cursors.
pub fn mouseCursorFor(cursor: zui.Cursor) c_int {
    return switch (cursor) {
        .default, .wait, .progress, .help => c.MOUSE_CURSOR_DEFAULT,
        .pointer, .grab => c.MOUSE_CURSOR_POINTING_HAND,
        .text => c.MOUSE_CURSOR_IBEAM,
        .crosshair => c.MOUSE_CURSOR_CROSSHAIR,
        .move, .grabbing => c.MOUSE_CURSOR_RESIZE_ALL,
        .not_allowed => c.MOUSE_CURSOR_NOT_ALLOWED,
        .resize_horizontal => c.MOUSE_CURSOR_RESIZE_EW,
        .resize_vertical => c.MOUSE_CURSOR_RESIZE_NS,
        .resize_nwse => c.MOUSE_CURSOR_RESIZE_NWSE,
        .resize_nesw => c.MOUSE_CURSOR_RESIZE_NESW,
    };
}

pub const InputOptions = struct {
    /// Layout units scrolled per notch of the mouse wheel.
    wheel_step: f32 = 40,
};

/// Turns the state raylib polled into a frame record's events. raylib
/// reports state, not events, so this goes through `zui.InputSampler`; a
/// press and release between two polls is lost, as it is to raylib.
pub const InputReader = struct {
    pub const max_keys = 64;
    pub const max_text_bytes = 256;
    pub const event_capacity = 3 * max_keys;

    sampler: zui.InputSampler = .{},
    keys: [max_keys]zui.Key = undefined,
    text: [max_text_bytes]u8 = undefined,
    events: [event_capacity]zui.Event = undefined,
    window_focused: bool = true,

    /// The events since the last read. They point into the reader, so they
    /// stay valid until the next read; `beginFrame` copies them.
    pub fn read(self: *InputReader, at: zui.Instant, options: InputOptions) []const zui.Event {
        return self.eventsFor(at, self.sample(options));
    }

    /// What raylib polled, as one sample.
    pub fn sample(self: *InputReader, options: InputOptions) zui.InputSampler.Sample {
        var buttons: std.EnumSet(zui.Button) = .initEmpty();
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) buttons.insert(.primary);
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_RIGHT)) buttons.insert(.secondary);
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_MIDDLE)) buttons.insert(.middle);

        var key_count: usize = 0;
        while (key_count < self.keys.len) {
            const raylib_key = c.GetKeyPressed();
            if (raylib_key == 0) break;
            self.keys[key_count] = keyFor(raylib_key);
            key_count += 1;
        }
        for (repeating_keys) |raylib_key| {
            if (key_count == self.keys.len) break;
            if (c.IsKeyPressedRepeat(raylib_key)) {
                self.keys[key_count] = keyFor(raylib_key);
                key_count += 1;
            }
        }

        var text_length: usize = 0;
        while (true) {
            const codepoint = c.GetCharPressed();
            if (codepoint <= 0) break;
            text_length += encodeCodepoint(@intCast(codepoint), self.text[text_length..]);
        }

        const pointer = c.GetMousePosition();
        return .{
            .pointer = if (c.IsCursorOnScreen()) .{ pointer.x, pointer.y } else null,
            .buttons = buttons,
            .wheel = wheelToScroll(c.GetMouseWheelMoveV(), options.wheel_step),
            .keys_pressed = self.keys[0..key_count],
            .modifiers = .{
                .shift = c.IsKeyDown(c.KEY_LEFT_SHIFT) or c.IsKeyDown(c.KEY_RIGHT_SHIFT),
                .control = c.IsKeyDown(c.KEY_LEFT_CONTROL) or c.IsKeyDown(c.KEY_RIGHT_CONTROL),
                .alt = c.IsKeyDown(c.KEY_LEFT_ALT) or c.IsKeyDown(c.KEY_RIGHT_ALT),
                .super = c.IsKeyDown(c.KEY_LEFT_SUPER) or c.IsKeyDown(c.KEY_RIGHT_SUPER),
            },
            .text = self.text[0..text_length],
        };
    }

    /// The events between the previous sample and `current`, then a focus
    /// change if the window gained or lost focus.
    pub fn eventsFor(self: *InputReader, at: zui.Instant, current: zui.InputSampler.Sample) []const zui.Event {
        var count = self.sampler.sample(at, current, self.events[0 .. self.events.len - 1]).len;
        const focused = c.IsWindowFocused();
        if (focused != self.window_focused) {
            self.window_focused = focused;
            self.events[count] = .{ .environment = .{ .window_focused = focused } };
            count += 1;
        }
        return self.events[0..count];
    }
};

/// Keys raylib repeats while held that a UI acts on again.
const repeating_keys = [_]c_int{
    c.KEY_TAB, c.KEY_ENTER, c.KEY_BACKSPACE, c.KEY_DELETE, c.KEY_LEFT,    c.KEY_RIGHT,
    c.KEY_UP,  c.KEY_DOWN,  c.KEY_HOME,      c.KEY_END,    c.KEY_PAGE_UP, c.KEY_PAGE_DOWN,
};

/// raylib's key codes are GLFW's, which name keys by the US layout.
pub fn keyFor(raylib_key: c_int) zui.Key {
    if (raylib_key >= c.KEY_A and raylib_key <= c.KEY_Z) return @enumFromInt(@intFromEnum(zui.Key.a) + @as(u32, @intCast(raylib_key - c.KEY_A)));
    if (raylib_key >= c.KEY_ZERO and raylib_key <= c.KEY_NINE) return @enumFromInt(@intFromEnum(zui.Key.digit_0) + @as(u32, @intCast(raylib_key - c.KEY_ZERO)));
    if (raylib_key >= c.KEY_F1 and raylib_key <= c.KEY_F12) return @enumFromInt(@intFromEnum(zui.Key.f1) + @as(u32, @intCast(raylib_key - c.KEY_F1)));
    return switch (raylib_key) {
        c.KEY_TAB => .tab,
        c.KEY_ENTER, c.KEY_KP_ENTER => .enter,
        c.KEY_ESCAPE => .escape,
        c.KEY_SPACE => .space,
        c.KEY_BACKSPACE => .backspace,
        c.KEY_DELETE => .delete,
        c.KEY_INSERT => .insert,
        c.KEY_LEFT => .left,
        c.KEY_RIGHT => .right,
        c.KEY_UP => .up,
        c.KEY_DOWN => .down,
        c.KEY_HOME => .home,
        c.KEY_END => .end,
        c.KEY_PAGE_UP => .page_up,
        c.KEY_PAGE_DOWN => .page_down,
        c.KEY_KB_MENU => .menu,
        c.KEY_LEFT_SHIFT, c.KEY_RIGHT_SHIFT => .shift,
        c.KEY_LEFT_CONTROL, c.KEY_RIGHT_CONTROL => .control,
        c.KEY_LEFT_ALT, c.KEY_RIGHT_ALT => .alt,
        c.KEY_LEFT_SUPER, c.KEY_RIGHT_SUPER => .super,
        c.KEY_CAPS_LOCK => .caps_lock,
        c.KEY_MINUS => .minus,
        c.KEY_EQUAL => .equals,
        c.KEY_LEFT_BRACKET => .left_bracket,
        c.KEY_RIGHT_BRACKET => .right_bracket,
        c.KEY_BACKSLASH => .backslash,
        c.KEY_SEMICOLON => .semicolon,
        c.KEY_APOSTROPHE => .apostrophe,
        c.KEY_GRAVE => .grave,
        c.KEY_COMMA => .comma,
        c.KEY_PERIOD => .period,
        c.KEY_SLASH => .slash,
        else => .unidentified,
    };
}

/// raylib reports wheel movement as positive when scrolling up (toward the
/// start); zui wants positive toward the end, in layout units.
pub fn wheelToScroll(wheel: c.Vector2, step: f32) [2]f32 {
    return .{ -wheel.x * step, -wheel.y * step };
}

/// Writes `codepoint` as UTF-8 if it fits; returns the bytes written.
fn encodeCodepoint(codepoint: u21, destination: []u8) usize {
    const length = std.unicode.utf8CodepointSequenceLength(codepoint) catch return 0;
    if (length > destination.len) return 0;
    return std.unicode.utf8Encode(codepoint, destination) catch 0;
}

// =====================================================================
// Rendering
// =====================================================================

/// The renderer contract, through raylib. It draws into raylib's current
/// target: the window between `BeginDrawing` and `EndDrawing`, or a render
/// texture between `BeginTextureMode` and `EndTextureMode`. raylib owns
/// that window, so its surface is `.library`.
///
/// ```zig
/// var renderer: zui_raylib.Renderer = .{ .text = &text };
/// const frame = ui.endFrame();
/// c.BeginDrawing();
/// c.ClearBackground(.{ .r = 30, .g = 30, .b = 36, .a = 255 });
/// try renderer.zuiSubmit(.library, frame);
/// c.EndDrawing();
/// ui.release(frame);
/// ```
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
    pub const ImageHandle = Texture;

    text: *const Text,
    /// Segments per rounded corner; raylib picks automatically at 0.
    corner_segments: c_int = 0,

    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
        if (surface != .library) return error.UnsupportedSurface;
        var scissors: ScissorStack = .{};
        for (frame.commands()) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| drawRectangle(bounds, rectangle.color, rectangle.corner_radius, self.corner_segments),
                .border => |border| drawBorder(bounds, border.color, border.widths, border.corner_radius, self.corner_segments),
                .text => |line| drawText(self.text, line.content, bounds, line.style.font, line.style.size, line.style.letter_spacing, line.style.color),
                .image => |image| drawTexture(image.handle, bounds),
                .clip_begin => |clip| scissors.push(clip),
                .clip_end => scissors.pop(),
            }
        }
    }
};

fn toRaylibRectangle(rect: zui.Rect) c.Rectangle {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn toRaylibColor(color: zui.Color) c.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

/// raylib rounds corners by a fraction of the shorter side, the same for
/// every corner, so the largest of zui's four radii is used.
pub fn roundness(bounds: zui.Rect, radius: zui.CornerRadius) f32 {
    const largest = @max(@max(radius.top_left, radius.top_right), @max(radius.bottom_left, radius.bottom_right));
    const shorter_side = @min(bounds.width, bounds.height);
    if (largest <= 0 or shorter_side <= 0) return 0;
    return std.math.clamp(2 * largest / shorter_side, 0, 1);
}

fn drawRectangle(bounds: zui.Rect, color: zui.Color, radius: zui.CornerRadius, segments: c_int) void {
    const corner_roundness = roundness(bounds, radius);
    if (corner_roundness > 0) {
        c.DrawRectangleRounded(toRaylibRectangle(bounds), corner_roundness, segments, toRaylibColor(color));
    } else {
        c.DrawRectangleRec(toRaylibRectangle(bounds), toRaylibColor(color));
    }
}

fn drawBorder(bounds: zui.Rect, color: zui.Color, widths: zui.Edges, radius: zui.CornerRadius, segments: c_int) void {
    const raylib_color = toRaylibColor(color);
    const uniform = widths.left == widths.right and widths.left == widths.top and widths.left == widths.bottom;
    const corner_roundness = roundness(bounds, radius);
    if (uniform and corner_roundness > 0) {
        c.DrawRectangleRoundedLinesEx(toRaylibRectangle(bounds), corner_roundness, segments, widths.left, raylib_color);
        return;
    }
    // Four bands drawn inside the bounds, as CSS borders are.
    c.DrawRectangleRec(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = widths.top }, raylib_color);
    c.DrawRectangleRec(.{ .x = bounds.x, .y = bounds.y + bounds.height - widths.bottom, .width = bounds.width, .height = widths.bottom }, raylib_color);
    c.DrawRectangleRec(.{ .x = bounds.x, .y = bounds.y + widths.top, .width = widths.left, .height = bounds.height - widths.top - widths.bottom }, raylib_color);
    c.DrawRectangleRec(.{ .x = bounds.x + bounds.width - widths.right, .y = bounds.y + widths.top, .width = widths.right, .height = bounds.height - widths.top - widths.bottom }, raylib_color);
}

fn drawText(text: *const Text, content: []const u8, bounds: zui.Rect, font: u16, size: f32, letter_spacing: f32, color: zui.Color) void {
    const raylib_font = text.fontFor(font);
    const spacing = text.spacing(size, letter_spacing);
    var x = bounds.x;
    var chunks: CStringChunks = .init(content);
    while (chunks.next()) |chunk| {
        c.DrawTextEx(raylib_font, chunk.ptr, .{ .x = x, .y = bounds.y }, size, spacing, toRaylibColor(color));
        x += c.MeasureTextEx(raylib_font, chunk.ptr, size, spacing).x + spacing;
    }
}

fn drawTexture(texture: Texture, bounds: zui.Rect) void {
    const source: c.Rectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(texture.width), .height = @floatFromInt(texture.height) };
    c.DrawTexturePro(texture, source, toRaylibRectangle(bounds), .{ .x = 0, .y = 0 }, 0, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
}

/// zui's clip rectangles are already intersected with every enclosing
/// clip, so restoring the enclosing one on `clip_end` is all that is needed.
const ScissorStack = struct {
    rects: [64]zui.Rect = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn push(self: *ScissorStack, rect: zui.Rect) void {
        if (self.depth == self.rects.len) {
            self.overflow += 1;
            return;
        }
        self.rects[self.depth] = rect;
        self.depth += 1;
        apply(rect);
    }

    fn pop(self: *ScissorStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
            return;
        }
        if (self.depth == 0) return;
        self.depth -= 1;
        c.EndScissorMode();
        if (self.depth > 0) apply(self.rects[self.depth - 1]);
    }

    fn apply(rect: zui.Rect) void {
        c.BeginScissorMode(@intFromFloat(@floor(rect.x)), @intFromFloat(@floor(rect.y)), @intFromFloat(@ceil(rect.width)), @intFromFloat(@ceil(rect.height)));
    }
};

test "chunks are NUL-terminated and split on code point boundaries" {
    var long: [CStringChunks.capacity + 10]u8 = undefined;
    @memset(&long, 'a');
    // A two-byte code point straddling the capacity boundary.
    long[CStringChunks.capacity - 1] = 0xC3;
    long[CStringChunks.capacity] = 0xA9;
    var chunks: CStringChunks = .init(&long);
    const first = chunks.next().?;
    try std.testing.expectEqual(@as(usize, CStringChunks.capacity - 1), first.len);
    try std.testing.expectEqual(@as(u8, 0), first.ptr[first.len]);
    const second = chunks.next().?;
    try std.testing.expectEqual(@as(u8, 0xC3), second[0]);
    try std.testing.expectEqual(@as(usize, 11), second.len);
    try std.testing.expectEqual(@as(?[:0]const u8, null), chunks.next());
}

test "roundness uses the largest radius against the shorter side" {
    const bounds: zui.Rect = .{ .width = 100, .height = 40 };
    try std.testing.expectEqual(@as(f32, 0), roundness(bounds, .zero));
    try std.testing.expectEqual(@as(f32, 0.5), roundness(bounds, .all(10)));
    try std.testing.expectEqual(@as(f32, 0.5), roundness(bounds, .{ .top_left = 10, .bottom_right = 4 }));
    try std.testing.expectEqual(@as(f32, 1), roundness(bounds, .all(500)));
}

test "the wheel is flipped and scaled into layout units" {
    try std.testing.expectEqual([2]f32{ -0.0, -40 }, wheelToScroll(.{ .x = 0, .y = 1 }, 40));
    try std.testing.expectEqual([2]f32{ 20, 0 }, wheelToScroll(.{ .x = -0.5, .y = 0 }, 40));
}

test "typed code points are encoded as UTF-8" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), encodeCodepoint('é', &buffer));
    try std.testing.expectEqualSlices(u8, "é", buffer[0..2]);
    try std.testing.expectEqual(@as(usize, 0), encodeCodepoint('€', buffer[0..2]));
}

test "raylib's keys map to zui's, letters and function keys included" {
    try std.testing.expectEqual(zui.Key.s, keyFor(c.KEY_S));
    try std.testing.expectEqual(zui.Key.digit_7, keyFor(c.KEY_SEVEN));
    try std.testing.expectEqual(zui.Key.f12, keyFor(c.KEY_F12));
    try std.testing.expectEqual(zui.Key.page_down, keyFor(c.KEY_PAGE_DOWN));
    try std.testing.expectEqual(zui.Key.unidentified, keyFor(c.KEY_KP_5));
}

test "the spacing after each glyph adds the style's letter spacing" {
    const text: Text = .{};
    try std.testing.expectEqual(@as(f32, 2), text.spacing(20, 0));
    try std.testing.expectEqual(@as(f32, 5), text.spacing(20, 3));
}

test "every cursor maps to one of raylib's" {
    try std.testing.expectEqual(@as(c_int, c.MOUSE_CURSOR_IBEAM), mouseCursorFor(.text));
    try std.testing.expectEqual(@as(c_int, c.MOUSE_CURSOR_POINTING_HAND), mouseCursorFor(.pointer));
}

test "config makes text raylib's and images raylib textures" {
    const derived = config(.{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Texture);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "the renderer draws exactly the base commands and images, into raylib's own window" {
    const Ui = zui.Context(config(.{ .limits = .{ .max_elements = 8 } }));
    try std.testing.expectEqual(6, @typeInfo(Ui.RenderCommand.Payload).@"union".fields.len);
    var text: Text = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: Renderer = .{ .text = &text };
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 100, 100 } } }, frame));
}
