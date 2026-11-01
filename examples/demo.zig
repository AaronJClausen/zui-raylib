//! The zui reference application.
//!
//! ```sh
//! zig build demo                                        # interactive window
//! zig build demo -- --screenshot demo.png               # render offscreen and save a PNG
//! zig build demo -- --screenshot demo.png --about       # ...with the About dialog open
//! zig build demo -- --screenshot grid.png --thumbnails  # ...in the thumbnail grid
//! zig build demo -- --hidden                            # run interactively in a hidden window
//! ```

const std = @import("std");
const Io = std.Io;
const zui_raylib = @import("zui_raylib");
const zui = zui_raylib.zui;
const c = zui_raylib.c;

const Ui = zui.Context(zui_raylib.config(.{ .max_elements = 4096 }), zui_raylib.Platform);

const Theme = struct {
    background: zui.Color = .rgb(0x16161c),
    panel: zui.Color = .rgb(0x20202a),
    sidebar: zui.Color = .rgb(0x1a1a22),
    text: zui.Color = .rgb(0xe8e8f0),
    muted_text: zui.Color = .rgb(0x9a9aae),
    accent: zui.Color = .rgb(0x5b8cff),
    border: zui.Color = .rgb(0x34344a),
    focus_ring: zui.Color = .rgb(0xffc65c),
    overlay: zui.Color = .rgba(0x00000099),
    button: std.EnumArray(zui.WidgetState, zui.Color) = .init(.{
        .idle = .rgb(0x2c2c3c),
        .hovered = .rgb(0x3a3a50),
        .pressed = .rgb(0x4a6ad0),
        .focused = .rgb(0x2c2c3c),
        .disabled = .rgb(0x24242e),
    }),
};

const theme: Theme = .{};

/// A thumbnail as a 4×4 grid of colors, produced by a background task.
const Thumbnail = struct { colors: [4][4]zui.Color };

const thumbnail_count = 600;
const thumbnail_columns = 7;
const thumbnail_size = 120;
const thumbnail_gap = 12;
const thumbnail_pitch = thumbnail_size + thumbnail_gap;
const thumbnail_rows = (thumbnail_count + thumbnail_columns - 1) / thumbnail_columns;

const App = struct {
    io: Io,
    view: enum { documents, thumbnails } = .documents,
    clicks: u32 = 0,
    last_action: []const u8 = "nothing yet",
    selected_item: ?usize = 2,
    about_open: bool = false,
    thumbnails: zui.TaskPool(Io.Cancelable!Thumbnail, 96) = .init,
};

const DetailsState = struct { open: bool };

const ids = zui.ids(.{ "toolbar", "new", "open", "save", "documents_view", "thumbnails_view", "about", "sidebar", "content", "details_toggle", "hover_me", "dialog_close", "grid" });

fn label(ui: *Ui, content: []const u8, size: f32, color: zui.Color) void {
    ui.text(content, .{ .size = size, .color = color });
}

fn button(ui: *Ui, id: zui.Id, text: []const u8) bool {
    const state = ui.widgetState(id);
    ui.open(.{
        .id = id,
        .focusable = true,
        .layout = .{ .padding = .symmetric(14, 8), .child_alignment = .{ .x = .center, .y = .center } },
        .background = theme.button.get(state),
        .corner_radius = .all(6),
        .border = if (ui.focused(id)) .{ .color = theme.focus_ring, .widths = .all(2) } else null,
    });
    defer ui.close();
    label(ui, text, 20, if (state == .disabled) theme.muted_text else theme.text);
    return ui.clicked(id);
}

fn toolbar(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = ids.toolbar,
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(56) }, .padding = .symmetric(12, 8), .child_gap = 8, .child_alignment = .{ .y = .center } },
        .background = theme.panel,
        .border = .{ .color = theme.border, .widths = .{ .bottom = 1 } },
    });
    defer ui.close();

    const actions = .{ .{ ids.new, "New" }, .{ ids.open, "Open" }, .{ ids.save, "Save" } };
    inline for (actions) |action| {
        if (button(ui, action[0], action[1])) {
            app.clicks += 1;
            app.last_action = action[1];
        }
    }
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
    if (button(ui, ids.documents_view, "Documents")) app.view = .documents;
    if (button(ui, ids.thumbnails_view, "Thumbnails")) app.view = .thumbnails;
    if (button(ui, ids.about, "About")) app.about_open = true;
}

fn sidebar(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = ids.sidebar,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(260), .height = .grow }, .padding = .all(8), .child_gap = 4 },
        .background = theme.sidebar,
        .scroll = .{},
    });
    defer ui.close();

    var name_buffer: [32]u8 = undefined;
    for (0..40) |index| {
        const id: zui.Id = .indexed("item", index);
        const selected = app.selected_item == index;
        const state = ui.widgetState(id);
        ui.open(.{
            .id = id,
            .focusable = true,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(36) }, .padding = .symmetric(12, 8), .child_alignment = .{ .y = .center } },
            .background = if (selected) theme.accent else if (state == .hovered or state == .pressed) theme.button.get(.hovered) else null,
            .corner_radius = .all(4),
            .border = if (ui.focused(id)) .{ .color = theme.focus_ring, .widths = .all(1) } else null,
        });
        const name = std.fmt.bufPrint(&name_buffer, "Document {d}", .{index + 1}) catch "Document";
        label(ui, name, 20, theme.text);
        ui.close();
        if (ui.clicked(id)) {
            app.selected_item = index;
            app.last_action = "selected a document";
        }
    }
}

fn mainPanel(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = ids.content,
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(28), .child_gap = 18 },
    });
    defer ui.close();

    label(ui, "zui + raylib", 40, theme.text);
    label(ui, "This window is laid out by zui and drawn by raylib. Every element is declared each frame as nested function calls; zui computes the layout and returns render commands, and the backend draws them. Resize the window to watch this paragraph re-wrap, scroll the list on the left with the wheel, and press Tab to move focus.", 20, theme.muted_text);

    ui.open(.{ .layout = .{ .child_gap = 12, .child_alignment = .{ .y = .center } } });
    const details = ui.state(ids.details_toggle, DetailsState);
    if (button(ui, ids.details_toggle, if (details.open) "Hide details" else "Show details")) details.open = !details.open;
    {
        ui.open(.{ .id = ids.hover_me, .interactive = true, .layout = .{ .padding = .symmetric(14, 8) }, .background = theme.button.get(ui.widgetState(ids.hover_me)), .corner_radius = .all(6) });
        defer ui.close();
        label(ui, "Hover me", 20, theme.text);
        if (ui.hovered(ids.hover_me)) {
            ui.open(.{
                .floating = .{ .anchor = .top_center, .attach_point = .bottom_center, .offset = .{ 0, 8 } },
                .layout = .{ .padding = .symmetric(10, 6) },
                .background = theme.focus_ring,
                .corner_radius = .all(4),
            });
            label(ui, "A floating tooltip", 20, theme.background);
            ui.close();
        }
    }
    ui.close();

    if (details.open) {
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(16), .child_gap = 6 },
            .background = theme.panel,
            .corner_radius = .all(8),
            .border = .{ .color = theme.border, .widths = .all(1) },
        });
        label(ui, "Details", 20, theme.text);
        label(ui, "This panel's open state lives in zui's state table under the toggle's id.", 20, theme.muted_text);
        ui.close();
    }

    var status_buffer: [128]u8 = undefined;
    const selected_name = if (app.selected_item) |index| index + 1 else 0;
    const status = std.fmt.bufPrint(&status_buffer, "Clicks: {d}   Last action: {s}   Selected: document {d}", .{ app.clicks, app.last_action, selected_name }) catch "";
    label(ui, status, 20, theme.muted_text);
}

/// The background task: a slow "load" (200–800 ms of cancelable sleep)
/// followed by colors derived from the index.
fn loadThumbnail(io: Io, index: usize) Io.Cancelable!Thumbnail {
    var prng: std.Random.DefaultPrng = .init(index *% 0x9E3779B97F4A7C15);
    const random = prng.random();
    try io.sleep(.fromMilliseconds(random.intRangeAtMost(i64, 200, 800)), .awake);
    var thumbnail: Thumbnail = undefined;
    const base_hue = random.int(u8);
    for (&thumbnail.colors, 0..) |*row, row_index| for (row, 0..) |*color, column_index| {
        const shade: u8 = @intCast(40 + (row_index + column_index) * 20);
        color.* = .{ .r = base_hue, .g = shade, .b = 255 - base_hue / 2 };
    };
    return thumbnail;
}

/// Only the rows near the visible part of the grid are declared. Rows that
/// scroll away stop being declared, so zui cancels their pending loads.
fn thumbnailGrid(ui: *Ui, app: *App) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 12 } });
    defer ui.close();

    const offset = ui.scrollOffset(ids.grid)[1];
    const visible_height = if (ui.rectOf(ids.grid)) |rect| rect.height else 600;
    const first_row: usize = @intFromFloat(@max(0, @floor(offset / thumbnail_pitch) - 1));
    const last_row: usize = @min(thumbnail_rows - 1, @as(usize, @intFromFloat(@floor((offset + visible_height) / thumbnail_pitch))) + 1);

    var stats_buffer: [160]u8 = undefined;
    const stats = app.thumbnails.stats;
    const summary = std.fmt.bufPrint(&stats_buffer, "{d} thumbnails, rows {d}-{d} declared.  Loads started {d}, completed {d}, canceled {d}", .{
        thumbnail_count, first_row + 1, last_row + 1, stats.started, stats.completed, stats.canceled,
    }) catch "";
    label(ui, summary, 20, theme.muted_text);

    ui.open(.{ .id = ids.grid, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = thumbnail_gap }, .scroll = .{} });
    defer ui.close();

    if (first_row > 0) ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first_row)) * thumbnail_pitch - thumbnail_gap) } } });
    for (first_row..last_row + 1) |row| {
        ui.open(.{ .layout = .{ .child_gap = thumbnail_gap } });
        defer ui.close();
        for (0..thumbnail_columns) |column| {
            const index = row * thumbnail_columns + column;
            if (index >= thumbnail_count) break;
            thumbnailCell(ui, app, index);
        }
    }
    const rows_below = thumbnail_rows - 1 - last_row;
    if (rows_below > 0) ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(rows_below)) * thumbnail_pitch - thumbnail_gap) } } });
}

fn thumbnailCell(ui: *Ui, app: *App, index: usize) void {
    const id: zui.Id = .indexed("thumbnail", index);
    ui.open(.{
        .id = id,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(thumbnail_size), .height = .fixed(thumbnail_size) }, .padding = .all(8), .child_alignment = .{ .x = .center, .y = .center } },
        .background = theme.panel,
        .corner_radius = .all(6),
    });
    defer ui.close();

    switch (app.thumbnails.request(ui, id, loadThumbnail, .{ app.io, index }, .{})) {
        .pending => label(ui, "loading", 20, theme.muted_text),
        .failed => label(ui, "canceled", 20, theme.muted_text),
        .ready => |thumbnail| for (thumbnail.colors) |row| {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } } });
            defer ui.close();
            for (row) |color| ui.box(.{ .layout = .{ .sizing = .grow_both }, .background = color });
        },
    }
}

fn aboutDialog(ui: *Ui, app: *App) void {
    if (!app.about_open) return;
    if (ui.keyPressed(.escape)) app.about_open = false;

    ui.open(.{
        .interactive = true,
        .floating = .{ .attach_to = .root, .z = 10 },
        .layout = .{ .sizing = .grow_both, .child_alignment = .{ .x = .center, .y = .center } },
        .background = theme.overlay,
    });
    defer ui.close();
    ui.open(.{
        .focus_scope = true,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(420) }, .padding = .all(24), .child_gap = 14 },
        .background = theme.panel,
        .corner_radius = .all(10),
        .border = .{ .color = theme.border, .widths = .all(1) },
    });
    defer ui.close();
    label(ui, "About", 30, theme.text);
    label(ui, "zui is an immediate-mode UI layout library for Zig. This dialog floats in its own layer and keeps tab focus inside it. Press Escape or Close.", 20, theme.muted_text);
    if (button(ui, ids.dialog_close, "Close")) app.about_open = false;
}

fn declare(ui: *Ui, app: *App) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .background = theme.background });
    defer ui.close();
    toolbar(ui, app);
    switch (app.view) {
        .documents => {
            ui.open(.{ .layout = .{ .sizing = .grow_both } });
            sidebar(ui, app);
            mainPanel(ui, app);
            ui.close();
        },
        .thumbnails => thumbnailGrid(ui, app),
    }
    aboutDialog(ui, app);
}

const Options = struct {
    screenshot_path: ?[:0]const u8 = null,
    about_open: bool = false,
    thumbnails: bool = false,
    hidden: bool = false,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--screenshot")) {
            index += 1;
            if (index == arguments.len) return error.MissingScreenshotPath;
            options.screenshot_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--about")) {
            options.about_open = true;
        } else if (std.mem.eql(u8, argument, "--thumbnails")) {
            options.thumbnails = true;
        } else if (std.mem.eql(u8, argument, "--hidden")) {
            options.hidden = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --screenshot <path>, --about, --thumbnails or --hidden\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    const screenshot_mode = options.screenshot_path != null;

    c.SetConfigFlags(if (screenshot_mode or options.hidden) c.FLAG_WINDOW_HIDDEN else c.FLAG_WINDOW_RESIZABLE | c.FLAG_MSAA_4X_HINT);
    c.InitWindow(1100, 700, "zui + raylib");
    defer c.CloseWindow();
    c.SetTargetFPS(60);

    var platform: zui_raylib.Platform = .{};
    var ui = try Ui.init(init.gpa, init.io, &platform);
    defer ui.deinit(init.gpa);

    var app: App = .{ .io = init.io, .about_open = options.about_open, .view = if (options.thumbnails) .thumbnails else .documents };
    defer app.thumbnails.deinit(&ui);
    const offscreen = if (screenshot_mode) c.LoadRenderTexture(c.GetScreenWidth(), c.GetScreenHeight()) else undefined;
    defer if (screenshot_mode) c.UnloadRenderTexture(offscreen);

    var frame_number: u32 = 0;
    while (!c.WindowShouldClose()) : (frame_number += 1) {
        var reader: zui_raylib.InputReader = .{};
        var input = reader.read(.{});
        if (screenshot_mode) {
            input.buttons = .initEmpty();
            switch (app.view) {
                // Rest the pointer on "Hover me" (known from the previous frame)
                // so the screenshot shows hover state and the tooltip.
                .documents => input.pointer = if (ui.rectOf(ids.hover_me)) |rect| centerOf(rect) else null,
                // Scroll far down once loads are underway, so the rows that
                // leave the screen have their pending loads canceled.
                .thumbnails => {
                    input.pointer = if (ui.rectOf(ids.grid)) |rect| centerOf(rect) else null;
                    if (frame_number == 5) input.wheel = .{ 0, 3000 };
                },
            }
        }

        ui.beginFrame(input);
        declare(&ui, &app);
        const frame = ui.endFrame() catch ui.lastFrame();
        defer ui.release(frame);

        if (screenshot_mode) c.BeginTextureMode(offscreen) else c.BeginDrawing();
        c.ClearBackground(.{ .r = theme.background.r, .g = theme.background.g, .b = theme.background.b, .a = 255 });
        zui_raylib.render(Ui.RenderCommand, &platform, frame.commands(), .{});
        if (screenshot_mode) {
            c.EndTextureMode();
        } else {
            // Sleep in EndDrawing until input or a task's wake, unless the
            // frame just drawn may already be out of date.
            if (ui.needsFrame()) c.DisableEventWaiting() else c.EnableEventWaiting();
            c.EndDrawing();
        }

        if (screenshot_mode and screenshotReady(&app, frame_number)) {
            var image = c.LoadImageFromTexture(offscreen.texture);
            defer c.UnloadImage(image);
            c.ImageFlipVertical(&image);
            if (!c.ExportImage(image, options.screenshot_path.?.ptr)) return error.ScreenshotFailed;
            std.debug.print("saved {s}\n", .{options.screenshot_path.?});
            const stats = app.thumbnails.stats;
            if (app.view == .thumbnails) std.debug.print("thumbnail loads: started {d}, completed {d}, canceled {d}\n", .{ stats.started, stats.completed, stats.canceled });
            break;
        }
        if (screenshot_mode and app.view == .thumbnails) init.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
}

fn centerOf(rect: zui.Rect) [2]f32 {
    return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
}

/// Documents: three frames (lay out, hover, show the tooltip). Thumbnails:
/// once some loads have finished and others are still pending.
fn screenshotReady(app: *const App, frame_number: u32) bool {
    return switch (app.view) {
        .documents => frame_number == 2,
        .thumbnails => app.thumbnails.stats.completed >= 20 or frame_number > 600,
    };
}
