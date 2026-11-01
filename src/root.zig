//! zui-raylib: renders zui frames with raylib and reads raylib input into
//! `zui.Input`. See README.md for usage.

const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");

/// The raw raylib bindings, translated from raylib.h.
pub const c = @import("raylib");

pub const Texture = c.Texture2D;

/// A `zui.Config` with raylib textures as image payloads; override any
/// field: `zui.Context(zui_raylib.config(.{ .max_elements = 8192 }), zui_raylib.Platform)`.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.ImageHandle = Texture;
    return result;
}

/// Text measurement through raylib fonts. `FontId` indexes `fonts`; with no
/// fonts loaded, raylib's built-in font is used for every id.
pub const Platform = struct {
    fonts: []const c.Font = &.{},
    /// Extra space between glyphs, as a fraction of the font size. raylib's
    /// own `DrawText` uses 0.1.
    letter_spacing: f32 = 0.1,

    /// Each glyph counts its advance plus the letter spacing after it, so
    /// that measuring "a", " " and "b" separately adds up to measuring
    /// "a b". zui measures words and spaces separately and sums them while
    /// wrapping; raylib's `MeasureTextEx` leaves out the spacing after the
    /// last glyph, which on its own under-measures every word and space.
    pub fn measureText(self: *Platform, text: []const u8, font: u16, size: f32) [2]f32 {
        const raylib_font = self.fontFor(font);
        const glyph_spacing = self.spacing(size);
        var width: f32 = 0;
        var height: f32 = size;
        var chunks: CStringChunks = .init(text);
        while (chunks.next()) |chunk| {
            const measured = c.MeasureTextEx(raylib_font, chunk.ptr, size, glyph_spacing);
            width += measured.x + glyph_spacing;
            height = @max(height, measured.y);
        }
        return .{ width, height };
    }

    /// zui snaps command bounds to whole pixels when this is declared.
    pub fn scale(_: *const Platform) f32 {
        return 1;
    }

    pub fn fontFor(self: *const Platform, font: u16) c.Font {
        return if (font < self.fonts.len) self.fonts[font] else c.GetFontDefault();
    }

    pub fn spacing(self: *const Platform, size: f32) f32 {
        return size * self.letter_spacing;
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
// Input
// =====================================================================

const key_map = [_]struct { raylib: c_int, zui: zui.Key }{
    .{ .raylib = c.KEY_TAB, .zui = .tab },
    .{ .raylib = c.KEY_ENTER, .zui = .enter },
    .{ .raylib = c.KEY_KP_ENTER, .zui = .enter },
    .{ .raylib = c.KEY_ESCAPE, .zui = .escape },
    .{ .raylib = c.KEY_SPACE, .zui = .space },
    .{ .raylib = c.KEY_BACKSPACE, .zui = .backspace },
    .{ .raylib = c.KEY_DELETE, .zui = .delete },
    .{ .raylib = c.KEY_LEFT, .zui = .left },
    .{ .raylib = c.KEY_RIGHT, .zui = .right },
    .{ .raylib = c.KEY_UP, .zui = .up },
    .{ .raylib = c.KEY_DOWN, .zui = .down },
    .{ .raylib = c.KEY_HOME, .zui = .home },
    .{ .raylib = c.KEY_END, .zui = .end },
    .{ .raylib = c.KEY_PAGE_UP, .zui = .page_up },
    .{ .raylib = c.KEY_PAGE_DOWN, .zui = .page_down },
};

pub const InputOptions = struct {
    /// Layout units scrolled per notch of the mouse wheel.
    wheel_step: f32 = 40,
};

/// Owns the memory `zui.Input`'s slices point into; keep it alive until
/// `beginFrame` returns (a local variable around the frame is enough).
pub const InputReader = struct {
    keys: [zui.max_keys_per_frame]zui.Key = undefined,
    text: [zui.max_text_input_bytes]u8 = undefined,

    pub fn read(self: *InputReader, options: InputOptions) zui.Input {
        var buttons: std.EnumSet(zui.Button) = .initEmpty();
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_LEFT)) buttons.insert(.primary);
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_RIGHT)) buttons.insert(.secondary);
        if (c.IsMouseButtonDown(c.MOUSE_BUTTON_MIDDLE)) buttons.insert(.middle);

        var key_count: usize = 0;
        for (key_map) |mapping| {
            if (key_count == self.keys.len) break;
            if (c.IsKeyPressed(mapping.raylib) or c.IsKeyPressedRepeat(mapping.raylib)) {
                self.keys[key_count] = mapping.zui;
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
            .viewport = .{ @floatFromInt(c.GetScreenWidth()), @floatFromInt(c.GetScreenHeight()) },
            .dt_seconds = c.GetFrameTime(),
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
            .text_input = self.text[0..text_length],
        };
    }
};

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

/// Hooks for payloads raylib cannot draw on its own.
pub fn RenderOptions(comptime Command: type) type {
    const Payload = @FieldType(Command, "payload");
    return struct {
        /// Required when `Config.CustomData` is not void.
        draw_custom: ?*const fn (data: @FieldType(Payload, "custom"), bounds: zui.Rect) void = null,
        /// Required when `Config.ImageHandle` is not `zui_raylib.Texture`.
        draw_image: ?*const fn (handle: @FieldType(Payload, "image"), bounds: zui.Rect) void = null,
        /// Segments per rounded corner; raylib picks automatically at 0.
        corner_segments: c_int = 0,
    };
}

/// Draws one frame's commands. Call between `BeginDrawing` (or
/// `BeginTextureMode`) and `EndDrawing`.
///
/// ```zig
/// const frame = ui.endFrame() catch ui.lastFrame();
/// c.BeginDrawing();
/// c.ClearBackground(.{ .r = 30, .g = 30, .b = 36, .a = 255 });
/// zui_raylib.render(Ui.RenderCommand, &platform, frame.commands(), .{});
/// c.EndDrawing();
/// ui.release(frame);
/// ```
pub fn render(comptime Command: type, platform: *const Platform, commands: []const Command, options: RenderOptions(Command)) void {
    const Payload = @FieldType(Command, "payload");
    const ImageHandle = @FieldType(Payload, "image");
    var scissors: ScissorStack = .{};
    for (commands) |command| {
        const bounds = command.bounds;
        switch (command.payload) {
            .rectangle => |rectangle| drawRectangle(bounds, rectangle.color, rectangle.corner_radius, options.corner_segments),
            .border => |border| drawBorder(bounds, border.color, border.widths, border.corner_radius, options.corner_segments),
            .text => |text| drawText(platform, text.content, bounds, text.style.font, text.style.size, text.style.color),
            .image => |handle| {
                if (ImageHandle == Texture) {
                    drawTexture(handle, bounds);
                } else if (options.draw_image) |draw_image| {
                    draw_image(handle, bounds);
                }
            },
            .custom => |data| if (options.draw_custom) |draw_custom| draw_custom(data, bounds),
            .clip_begin => |clip| scissors.push(clip),
            .clip_end => scissors.pop(),
        }
    }
}

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

fn drawText(platform: *const Platform, content: []const u8, bounds: zui.Rect, font: u16, size: f32, color: zui.Color) void {
    const raylib_font = platform.fontFor(font);
    const spacing = platform.spacing(size);
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

test "config makes images raylib textures" {
    const derived = config(.{ .max_elements = 128 });
    try std.testing.expect(derived.ImageHandle == Texture);
    try std.testing.expectEqual(@as(u32, 128), derived.max_elements);
}
