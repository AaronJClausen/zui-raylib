const std = @import("std");
const zui_raylib = @import("zui_raylib");
const zui = zui_raylib.zui;
const c = zui_raylib.c;
const zui_testing = @import("zui_testing");

/// Draws into a render texture of a hidden window, and reads each frame
/// back as an image.
const RenderTextureHarness = struct {
    pub const config = zui_raylib.config(.{});

    text_contract: zui_raylib.Text = .{},
    drawn: zui_raylib.Renderer,
    target: c.RenderTexture2D,
    pictures: [4]c.Texture2D = undefined,
    picture_count: usize = 0,
    read_back: ?c.Image = null,

    fn init(self: *RenderTextureHarness) void {
        c.SetTraceLogLevel(c.LOG_WARNING);
        c.SetConfigFlags(c.FLAG_WINDOW_HIDDEN);
        c.InitWindow(zui_testing.renderer_viewport[0], zui_testing.renderer_viewport[1], "zui renderer suite");
        self.* = .{
            .drawn = .{ .text = &self.text_contract },
            .target = c.LoadRenderTexture(zui_testing.renderer_viewport[0], zui_testing.renderer_viewport[1]),
        };
    }

    fn deinit(self: *RenderTextureHarness) void {
        if (self.read_back) |frame_pixels| c.UnloadImage(frame_pixels);
        for (self.pictures[0..self.picture_count]) |picture| c.UnloadTexture(picture);
        c.UnloadRenderTexture(self.target);
        c.CloseWindow();
    }

    pub fn renderer(self: *RenderTextureHarness) *zui_raylib.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *RenderTextureHarness) *zui_raylib.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(self: *RenderTextureHarness, size: [2]u32) zui.Surface {
        std.debug.assert(size[0] == self.target.texture.width and size[1] == self.target.texture.height);
        c.BeginTextureMode(self.target);
        c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        return .library;
    }

    pub fn endDraw(self: *RenderTextureHarness) void {
        c.EndTextureMode();
        if (self.read_back) |frame_pixels| c.UnloadImage(frame_pixels);
        self.read_back = c.LoadImageFromTexture(self.target.texture);
    }

    /// A render texture's rows are stored bottom up.
    pub fn pixel(self: *RenderTextureHarness, x: u32, y: u32) zui.Color {
        const frame_pixels = self.read_back.?;
        const color = c.GetImageColor(frame_pixels, @intCast(x), frame_pixels.height - 1 - @as(c_int, @intCast(y)));
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
    }

    pub fn image(self: *RenderTextureHarness, color: zui.Color) zui_raylib.Texture {
        const solid = c.GenImageColor(16, 16, .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a });
        defer c.UnloadImage(solid);
        const picture = c.LoadTextureFromImage(solid);
        self.pictures[self.picture_count] = picture;
        self.picture_count += 1;
        return picture;
    }
};

test "the renderer passes zui's renderer suite" {
    var harness: RenderTextureHarness = undefined;
    harness.init();
    defer harness.deinit();
    try zui_testing.expectRendererConforms(zui_raylib.Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
}
