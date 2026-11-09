//! zui-raylib: a zui renderer and adapter host on raylib. See README.md.

const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_app = @import("zui_app");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const zui_async = @import("zui_async");
pub const zui_tracy = @import("zui_tracy");

/// The raw raylib bindings, translated from raylib.h.
pub const c = @import("raylib");
/// raylib's immediate-mode layer, for the textured triangles raylib
/// itself does not draw.
const rlgl = @import("rlgl");

pub const Texture = c.Texture2D;

/// GLFW, compiled into raylib with its desktop platform (the default).
/// raylib can neither wake its event wait from another thread nor wait
/// until an instant, so the host reaches past it.
const glfw = struct {
    const Window = opaque {};
    extern fn glfwPostEmptyEvent() void;
    extern fn glfwWaitEvents() void;
    extern fn glfwWaitEventsTimeout(seconds: f64) void;
    extern fn glfwGetCurrentContext() ?*Window;
    extern fn glfwWindowShouldClose(window: ?*Window) c_int;
    extern fn glfwSetWindowShouldClose(window: ?*Window, value: c_int) void;
    extern fn glfwSetKeyCallback(window: ?*Window, callback: ?*const KeyCallback) ?*const KeyCallback;
    extern fn glfwSetCharCallback(window: ?*Window, callback: ?*const CharCallback) ?*const CharCallback;
    extern fn glfwSetMouseButtonCallback(window: ?*Window, callback: ?*const ButtonCallback) ?*const ButtonCallback;
    extern fn glfwSetCursorPosCallback(window: ?*Window, callback: ?*const PositionCallback) ?*const PositionCallback;
    extern fn glfwSetScrollCallback(window: ?*Window, callback: ?*const PositionCallback) ?*const PositionCallback;
    extern fn glfwSetCursorEnterCallback(window: ?*Window, callback: ?*const FlagCallback) ?*const FlagCallback;
    extern fn glfwSetWindowFocusCallback(window: ?*Window, callback: ?*const FlagCallback) ?*const FlagCallback;
    extern fn glfwSetWindowSizeCallback(window: ?*Window, callback: ?*const SizeCallback) ?*const SizeCallback;
    extern fn glfwSetWindowRefreshCallback(window: ?*Window, callback: ?*const WindowCallback) ?*const WindowCallback;
    extern fn glfwSetWindowCloseCallback(window: ?*Window, callback: ?*const WindowCallback) ?*const WindowCallback;

    const KeyCallback = fn (?*Window, c_int, c_int, c_int, c_int) callconv(.c) void;
    const CharCallback = fn (?*Window, c_uint) callconv(.c) void;
    const ButtonCallback = fn (?*Window, c_int, c_int, c_int) callconv(.c) void;
    const PositionCallback = fn (?*Window, f64, f64) callconv(.c) void;
    const FlagCallback = fn (?*Window, c_int) callconv(.c) void;
    const SizeCallback = fn (?*Window, c_int, c_int) callconv(.c) void;
    const WindowCallback = fn (?*Window) callconv(.c) void;
};

/// Set by every OS event that should end a wait, from GLFW callbacks put
/// in front of raylib's own. GLFW's callbacks carry no context, and the
/// host has one window, so this is global.
const os_event = struct {
    var arrived: bool = false;
    var key: ?*const glfw.KeyCallback = null;
    var char: ?*const glfw.CharCallback = null;
    var button: ?*const glfw.ButtonCallback = null;
    var cursor: ?*const glfw.PositionCallback = null;
    var scroll: ?*const glfw.PositionCallback = null;
    var enter: ?*const glfw.FlagCallback = null;
    var focus: ?*const glfw.FlagCallback = null;
    var size: ?*const glfw.SizeCallback = null;
    var refresh: ?*const glfw.WindowCallback = null;
    var close: ?*const glfw.WindowCallback = null;

    fn install(window: ?*glfw.Window) void {
        key = glfw.glfwSetKeyCallback(window, onKey);
        char = glfw.glfwSetCharCallback(window, onChar);
        button = glfw.glfwSetMouseButtonCallback(window, onButton);
        cursor = glfw.glfwSetCursorPosCallback(window, onCursor);
        scroll = glfw.glfwSetScrollCallback(window, onScroll);
        enter = glfw.glfwSetCursorEnterCallback(window, onEnter);
        focus = glfw.glfwSetWindowFocusCallback(window, onFocus);
        size = glfw.glfwSetWindowSizeCallback(window, onSize);
        refresh = glfw.glfwSetWindowRefreshCallback(window, onRefresh);
        close = glfw.glfwSetWindowCloseCallback(window, onClose);
    }

    fn onKey(window: ?*glfw.Window, key_code: c_int, scancode: c_int, action: c_int, modifiers: c_int) callconv(.c) void {
        arrived = true;
        if (key) |previous| previous(window, key_code, scancode, action, modifiers);
    }
    fn onChar(window: ?*glfw.Window, codepoint: c_uint) callconv(.c) void {
        arrived = true;
        if (char) |previous| previous(window, codepoint);
    }
    fn onButton(window: ?*glfw.Window, mouse_button: c_int, action: c_int, modifiers: c_int) callconv(.c) void {
        arrived = true;
        if (button) |previous| previous(window, mouse_button, action, modifiers);
    }
    fn onCursor(window: ?*glfw.Window, x: f64, y: f64) callconv(.c) void {
        arrived = true;
        if (cursor) |previous| previous(window, x, y);
    }
    fn onScroll(window: ?*glfw.Window, x: f64, y: f64) callconv(.c) void {
        arrived = true;
        if (scroll) |previous| previous(window, x, y);
    }
    fn onEnter(window: ?*glfw.Window, entered: c_int) callconv(.c) void {
        arrived = true;
        if (enter) |previous| previous(window, entered);
    }
    fn onFocus(window: ?*glfw.Window, focused: c_int) callconv(.c) void {
        arrived = true;
        if (focus) |previous| previous(window, focused);
    }
    fn onSize(window: ?*glfw.Window, width: c_int, height: c_int) callconv(.c) void {
        arrived = true;
        if (size) |previous| previous(window, width, height);
    }
    fn onRefresh(window: ?*glfw.Window) callconv(.c) void {
        arrived = true;
        if (refresh) |previous| previous(window);
    }
    fn onClose(window: ?*glfw.Window) callconv(.c) void {
        arrived = true;
        if (close) |previous| previous(window);
    }
};

// =====================================================================
// The host: one window, its input, its waits and its requests
// =====================================================================

/// zui's host contract on raylib's window, with one window and no system
/// material. Input goes through `zui.InputSampler`, since raylib reports
/// state; waits go through GLFW, so an idle window sleeps until input, a
/// wake or the instant `nextFrame` names. Its surface is `.library`:
/// `zuiPoll` begins raylib's drawing and `zuiWait` presents it.
///
/// ```zig
/// const App = struct {
///     pub const Host = zui_raylib.Host;
///     pub const Renderer = zui_raylib.Renderer;
///     // ...
/// };
/// ```
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
    pub const zui_capabilities: zui.HostCapabilities = .{};

    io: std.Io,
    window: ?*glfw.Window,
    input: InputOptions = .{},
    /// What each frame is cleared to before the renderer draws.
    clear_color: zui.Color = .black,
    /// `.immediately` waits until this long after the last frame began:
    /// the monitor's refresh interval.
    frame_interval_ns: u64,
    reader: InputReader = .{},
    scripted: [scripted_capacity]zui.InputSampler.Sample = undefined,
    scripted_first: usize = 0,
    scripted_count: usize = 0,
    woken: std.atomic.Value(bool) = .init(false),
    drawing: bool = false,
    closed: bool = false,
    offscreen: ?c.RenderTexture2D = null,
    applied_cursor: ?zui.Cursor = null,
    frame_began: zui.Instant = .zero,
    /// When `init` had opened the window, and when the first frame was
    /// presented: what an application's cold start is made of.
    opened_at: zui.Instant = .zero,
    first_present: ?zui.Instant = null,

    const scripted_capacity = 16;

    pub fn init(self: *Host, io: std.Io, window: zui.WindowOptions) !void {
        var flags: c_uint = c.FLAG_MSAA_4X_HINT;
        if (!window.visible) flags |= c.FLAG_WINDOW_HIDDEN;
        if (window.resizable) flags |= c.FLAG_WINDOW_RESIZABLE;
        c.SetTraceLogLevel(c.LOG_WARNING);
        c.SetConfigFlags(flags);
        c.InitWindow(@intCast(window.size[0]), @intCast(window.size[1]), window.title.ptr);
        if (!c.IsWindowReady()) return error.WindowUnavailable;
        // Escape belongs to the application, not to closing the window.
        c.SetExitKey(c.KEY_NULL);
        const refresh_rate = c.GetMonitorRefreshRate(c.GetCurrentMonitor());
        self.* = .{
            .io = io,
            .window = glfw.glfwGetCurrentContext(),
            .frame_interval_ns = std.time.ns_per_s / @as(u64, @intCast(if (refresh_rate > 0) refresh_rate else 60)),
            .opened_at = .fromTimestamp(std.Io.Timestamp.now(io, .awake)),
        };
        os_event.install(self.window);
    }

    pub fn deinit(self: *Host) void {
        if (self.offscreen) |texture| c.UnloadRenderTexture(texture);
        c.CloseWindow();
        self.* = undefined;
    }

    /// Draws every frame into a texture of the window's size instead of
    /// the window, for `saveScreenshot`.
    pub fn drawOffscreen(self: *Host) void {
        if (self.offscreen == null) self.offscreen = c.LoadRenderTexture(c.GetScreenWidth(), c.GetScreenHeight());
    }

    /// Saves the frame drawn offscreen as an image file, such as a PNG.
    /// Call it once the frame was submitted, as from the loader.
    pub fn saveScreenshot(self: *Host, path: [:0]const u8) !void {
        const texture = self.offscreen orelse return error.NotDrawingOffscreen;
        self.endDrawing();
        var image = c.LoadImageFromTexture(texture.texture);
        defer c.UnloadImage(image);
        c.ImageFlipVertical(&image);
        if (!c.ExportImage(image, path.ptr)) return error.ScreenshotFailed;
    }

    /// Input for a later poll instead of raylib's, one sample a poll, as a
    /// test or a scripted capture wants. Its slices must stay valid until
    /// that poll.
    pub fn script(self: *Host, sample: zui.InputSampler.Sample) error{Full}!void {
        if (self.scripted_count == scripted_capacity) return error.Full;
        self.scripted[(self.scripted_first + self.scripted_count) % scripted_capacity] = sample;
        self.scripted_count += 1;
    }

    /// Closes the window as its close button would: the next poll is false.
    pub fn close(self: *Host) void {
        glfw.glfwSetWindowShouldClose(self.window, 1);
        glfw.glfwPostEmptyEvent();
    }

    pub fn zuiPoll(self: *Host, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        std.debug.assert(window == .main);
        // raylib's own flag lasts one frame, GLFW's until raylib polls.
        if (self.closed or c.WindowShouldClose() or glfw.glfwWindowShouldClose(self.window) != 0) {
            self.closed = true;
            return false;
        }
        const at = self.now();
        self.frame_began = at;
        record.begin(.{ .now = at, .viewport = .{ @floatFromInt(c.GetScreenWidth()), @floatFromInt(c.GetScreenHeight()) }, .scale = renderScale() });
        const sample = self.nextScripted() orelse self.reader.sample(self.input);
        for (self.reader.eventsFor(at, sample)) |event| switch (event) {
            .text => |text| record.appendText(text),
            else => record.append(event),
        };
        os_event.arrived = false;

        if (self.offscreen) |texture| c.BeginTextureMode(texture) else c.BeginDrawing();
        c.ClearBackground(toRaylibColor(self.clear_color));
        self.drawing = true;
        return true;
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    /// Presents the frame, then sleeps until input arrives, the host is
    /// woken, or the instant `next` names. The wake flag is cleared after
    /// the wait, never before, so a wake that came first ends it at once.
    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        if (self.drawing) self.endDrawing() else c.PollInputEvents();
        const deadline: ?zui.Instant = switch (next) {
            .immediately => self.frame_began.addNanoseconds(self.frame_interval_ns),
            .at => |instant| instant,
            .on_event => null,
        };
        while (!self.woken.load(.acquire) and !os_event.arrived) {
            if (deadline) |instant| {
                const remaining = instant.nanoseconds -| self.now().nanoseconds;
                if (remaining == 0) break;
                glfw.glfwWaitEventsTimeout(@as(f64, @floatFromInt(remaining)) / std.time.ns_per_s);
            } else {
                glfw.glfwWaitEvents();
            }
        }
        self.woken.store(false, .release);
    }

    pub fn zuiSurface(_: *Host, window: zui.WindowId) zui.Surface {
        std.debug.assert(window == .main);
        return .library;
    }

    /// Sets the cursor. raylib cannot place an IME window, so a text-input
    /// request is not applied.
    pub fn zuiApply(self: *Host, window: zui.WindowId, requests: zui.HostRequests) void {
        std.debug.assert(window == .main);
        if (self.applied_cursor == requests.cursor) return;
        self.applied_cursor = requests.cursor;
        c.SetMouseCursor(mouseCursorFor(requests.cursor));
    }

    pub fn now(self: *const Host) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    /// raylib polls input in `EndDrawing`, and an offscreen frame polls it
    /// the same way.
    fn endDrawing(self: *Host) void {
        if (!self.drawing) return;
        self.drawing = false;
        if (self.offscreen != null) {
            c.EndTextureMode();
            c.PollInputEvents();
        } else {
            c.EndDrawing();
            if (self.first_present == null) self.first_present = self.now();
        }
    }

    fn nextScripted(self: *Host) ?zui.InputSampler.Sample {
        if (self.scripted_count == 0) return null;
        const sample = self.scripted[self.scripted_first];
        self.scripted_first = (self.scripted_first + 1) % scripted_capacity;
        self.scripted_count -= 1;
        return sample;
    }

    /// GLFW lets any thread post an empty event, which ends a wait in
    /// progress; the flag ends the next one.
    fn wake(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.woken.store(true, .release);
        glfw.glfwPostEmptyEvent();
    }
};

fn renderScale() f32 {
    const screen_width = c.GetScreenWidth();
    if (screen_width <= 0) return 1;
    return @as(f32, @floatFromInt(c.GetRenderWidth())) / @as(f32, @floatFromInt(screen_width));
}

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
    /// change if the window gained or lost focus. They stay valid until
    /// the next call.
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
// The renderer, which is also the text contract
// =====================================================================

/// zui's renderer and text contracts through raylib. It draws into
/// raylib's current target: the window between `BeginDrawing` and
/// `EndDrawing`, or a render texture between `BeginTextureMode` and
/// `EndTextureMode`. raylib owns that window, so its surface is
/// `.library`. `FontId` indexes `fonts`; with none loaded, raylib's
/// built-in font is used for every id. raylib's GL context belongs to the
/// thread that opened the window, so it does not declare
/// `zui_render_thread`.
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_raylib.Renderer, .{}));
/// var renderer: zui_raylib.Renderer = .{};
/// var ui = try Ui.init(gpa, io, &renderer);
/// ```
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
    pub const ImageHandle = Texture;

    fonts: []const c.Font = &.{},
    /// Space raylib's fonts need between glyphs, as a fraction of the size,
    /// before the style's own letter spacing. raylib's `DrawText` uses 0.1.
    font_spacing: f32 = 0.1,
    /// Segments per rounded corner; at 0, raylib picks for rectangles and
    /// borders, and an image's corners take one segment per two units of
    /// radius.
    corner_segments: c_int = 0,

    /// Each glyph counts its advance plus the spacing after it, so that
    /// measuring "a", " " and "b" separately adds up to measuring "a b",
    /// which zui relies on when it wraps. raylib's `MeasureTextEx` leaves
    /// out the spacing after the last glyph.
    pub fn zuiMeasure(self: *Renderer, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
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

    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
        if (surface != .library) return error.UnsupportedSurface;
        var scissors: ScissorStack = .{};
        for (frame.commands()) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| drawRectangle(bounds, rectangle.color, rectangle.corner_radius, self.corner_segments),
                .border => |border| drawBorder(bounds, border.color, border.widths, border.corner_radius, self.corner_segments),
                .text => |line| self.drawText(line.content, bounds, line.style),
                .image => |image| drawImage(image.handle, bounds, image.tint, image.corner_radius, self.corner_segments),
                .clip_begin => |clip| scissors.push(clip),
                .clip_end => scissors.pop(),
            }
        }
    }

    pub fn fontFor(self: *const Renderer, font: u16) c.Font {
        return if (font < self.fonts.len) self.fonts[font] else c.GetFontDefault();
    }

    /// raylib's spacing between glyphs for text of `size` with the style's
    /// `letter_spacing`.
    pub fn spacing(self: *const Renderer, size: f32, letter_spacing: f32) f32 {
        return size * self.font_spacing + letter_spacing;
    }

    fn drawText(self: *const Renderer, content: []const u8, bounds: zui.Rect, style: anytype) void {
        const raylib_font = self.fontFor(style.font);
        const glyph_spacing = self.spacing(style.size, style.letter_spacing);
        var x = bounds.x;
        var chunks: CStringChunks = .init(content);
        while (chunks.next()) |chunk| {
            c.DrawTextEx(raylib_font, chunk.ptr, .{ .x = x, .y = bounds.y }, style.size, glyph_spacing, toRaylibColor(style.color));
            x += c.MeasureTextEx(raylib_font, chunk.ptr, style.size, glyph_spacing).x + glyph_spacing;
        }
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

fn hasRoundedCorners(radius: zui.CornerRadius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
}

/// raylib multiplies a texture by a tint, but cannot round its corners,
/// so a rounded image is a fan of textured triangles from its center.
fn drawImage(texture: Texture, bounds: zui.Rect, tint: zui.Color, radius: zui.CornerRadius, corner_segments: c_int) void {
    if (!hasRoundedCorners(radius) or bounds.width <= 0 or bounds.height <= 0) {
        const source: c.Rectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(texture.width), .height = @floatFromInt(texture.height) };
        c.DrawTexturePro(texture, source, toRaylibRectangle(bounds), .{ .x = 0, .y = 0 }, 0, toRaylibColor(tint));
        return;
    }
    var outline: ImageOutline = .{};
    outline.trace(bounds, radius, corner_segments);
    const center: [2]f32 = .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
    _ = rlgl.rlCheckRenderBatchLimit(@intCast(3 * outline.count));
    rlgl.rlSetTexture(texture.id);
    rlgl.rlBegin(rlgl.RL_TRIANGLES);
    rlgl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);
    for (0..outline.count) |index| {
        const next = (index + 1) % outline.count;
        for ([3][2]f32{ center, outline.points[index], outline.points[next] }) |point| {
            rlgl.rlTexCoord2f((point[0] - bounds.x) / bounds.width, (point[1] - bounds.y) / bounds.height);
            rlgl.rlVertex2f(point[0], point[1]);
        }
    }
    rlgl.rlEnd();
    rlgl.rlSetTexture(0);
}

/// The points around a rounded rectangle, each corner with its own radius,
/// counter-clockwise on screen from the top of the top-left corner, as
/// raylib's culling wants triangles wound.
const ImageOutline = struct {
    const max_segments = 32;

    points: [4 * (max_segments + 1)][2]f32 = undefined,
    count: usize = 0,

    fn trace(self: *ImageOutline, bounds: zui.Rect, radius: zui.CornerRadius, corner_segments: c_int) void {
        const limit = @min(bounds.width, bounds.height) / 2;
        const left = bounds.x;
        const top = bounds.y;
        const right = bounds.x + bounds.width;
        const bottom = bounds.y + bounds.height;
        const corners = [4]struct { x: f32, y: f32, radius: f32, toward_x: f32, toward_y: f32 }{
            .{ .x = left, .y = top, .radius = radius.top_left, .toward_x = 1, .toward_y = 1 },
            .{ .x = left, .y = bottom, .radius = radius.bottom_left, .toward_x = 1, .toward_y = -1 },
            .{ .x = right, .y = bottom, .radius = radius.bottom_right, .toward_x = -1, .toward_y = -1 },
            .{ .x = right, .y = top, .radius = radius.top_right, .toward_x = -1, .toward_y = 1 },
        };
        self.count = 0;
        for (corners, 0..) |corner, corner_index| {
            const corner_radius = std.math.clamp(corner.radius, 0, limit);
            const segments: usize = if (corner_radius == 0) 0 else if (corner_segments > 0)
                @intCast(@min(corner_segments, max_segments))
            else
                @intFromFloat(std.math.clamp(@ceil(corner_radius / 2), 4, max_segments));
            const arc_x = corner.x + corner.toward_x * corner_radius;
            const arc_y = corner.y + corner.toward_y * corner_radius;
            // Angles are measured with y pointing down, so a decreasing angle
            // turns counter-clockwise on screen.
            const start_angle = 1.5 * std.math.pi - 0.5 * std.math.pi * @as(f32, @floatFromInt(corner_index));
            for (0..segments + 1) |step| {
                const angle = start_angle - 0.5 * std.math.pi * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(@max(segments, 1)));
                self.points[self.count] = .{ arc_x + @cos(angle) * corner_radius, arc_y + @sin(angle) * corner_radius };
                self.count += 1;
            }
        }
    }
};

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

test "an image's outline rounds each corner by its own radius, wound counter-clockwise on screen" {
    var outline: ImageOutline = .{};
    outline.trace(.{ .x = 10, .y = 20, .width = 100, .height = 40 }, .{ .top_left = 8, .bottom_right = 500 }, 4);
    try std.testing.expectEqual(@as(usize, 5 + 1 + 5 + 1), outline.count);
    try std.testing.expectApproxEqAbs(@as(f32, 18), outline.points[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), outline.points[0][1], 0.001);
    try std.testing.expectEqual([2]f32{ 10, 60 }, outline.points[5]);
    try std.testing.expectEqual([2]f32{ 110, 20 }, outline.points[11]);
    var twice_signed_area: f32 = 0;
    for (0..outline.count) |index| {
        const here = outline.points[index];
        const next = outline.points[(index + 1) % outline.count];
        twice_signed_area += here[0] * next[1] - next[0] * here[1];
    }
    try std.testing.expect(twice_signed_area < 0);
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
    const renderer: Renderer = .{};
    try std.testing.expectEqual(@as(f32, 2), renderer.spacing(20, 0));
    try std.testing.expectEqual(@as(f32, 5), renderer.spacing(20, 3));
}

test "every cursor maps to one of raylib's" {
    try std.testing.expectEqual(@as(c_int, c.MOUSE_CURSOR_IBEAM), mouseCursorFor(.text));
    try std.testing.expectEqual(@as(c_int, c.MOUSE_CURSOR_POINTING_HAND), mouseCursorFor(.pointer));
}

test "zui_app's config makes the renderer the text contract and images raylib textures" {
    const derived = zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Texture);
    try std.testing.expect(derived.Text == Renderer);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "the renderer draws exactly the base commands and images, into raylib's own window" {
    comptime zui.checkHostAndRenderer(Host, Renderer);
    const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 } }));
    try std.testing.expectEqual(6, @typeInfo(Ui.RenderCommand.Payload).@"union".fields.len);
    var renderer: Renderer = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &renderer);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 100, 100 } } }, frame));
}
