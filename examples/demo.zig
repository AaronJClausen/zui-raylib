//! The zui reference application.
//!
//! ```sh
//! zig build demo                                        # interactive window
//! zig build demo -- --screenshot demo.png               # render offscreen and save a PNG
//! zig build demo -- --screenshot demo.png --about       # ...with the About dialog open
//! zig build demo -- --screenshot grid.png --thumbnails  # ...in the thumbnail grid
//! zig build demo -- --screenshot settings.png --settings # ...in the generated settings editor
//! zig build demo -- --hidden                            # run interactively in a hidden window
//! zig build demo -- --measure-idle [--thumbnails]       # report the CPU time used over 10 idle seconds
//! ```

const std = @import("std");
const zui_raylib = @import("zui_raylib");
const zui = zui_raylib.zui;
const zui_widgets = zui_raylib.zui_widgets;
const zui_reflect = zui_raylib.zui_reflect;
const zui_tracy = zui_raylib.zui_tracy;
const c = zui_raylib.c;
const thumbnails = @import("thumbnails.zig");

const AppSources = struct {
    thumbnails: thumbnails.Loads = .{},
};

const Ui = zui.Context(zui_raylib.config(.{
    .Sources = AppSources,
    .features = .{ .Tracer = zui_tracy.Tracer },
}));

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

const widgets: zui_widgets.Widgets(Ui) = .{ .theme = .{
    .text = .{ .size = 20, .color = theme.text },
    .muted_text_color = theme.muted_text,
    .control = theme.button,
    .border_color = theme.border,
    .accent = theme.accent,
    .track = theme.border,
    .focus_ring = theme.focus_ring,
    .popup_background = theme.panel,
    .corner_radius = 6,
    .control_height = 38,
    .horizontal_padding = 14,
    .checkbox_size = 22,
    .slider_thumb_size = .{ 14, 24 },
    .label_width = 200,
} };

/// Everything in the Settings view is generated from this struct by
/// `zui_reflect.inspector`.
const Preferences = struct {
    display_name: zui_widgets.EditableText,
    color_scheme: enum { midnight, dusk, high_contrast } = .midnight,
    interface_scale: f32 = 1,
    font_size: u8 = 20,
    show_tooltips: bool = true,
    autosave: Autosave = .{},
    build: []const u8 = "zui-raylib 0.4.0",
    times_saved: u32 = 0,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .display_name = .{ .placeholder = "Your name" },
        .interface_scale = .{ .min = 0.75, .max = 2, .step = 0.05 },
        .font_size = .{ .min = 12, .step = 2 },
        .times_saved = .{ .hidden = true },
    } };
};

const Autosave = struct {
    enabled: bool = true,
    interval_minutes: u16 = 5,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .interval_minutes = .{ .min = 1, .max = 60 },
    } };
};

const thumbnail_columns = 7;
const thumbnail_size = 120;
const thumbnail_gap = 12;
const thumbnail_pitch = thumbnail_size + thumbnail_gap;
const thumbnail_rows = (thumbnails.count + thumbnail_columns - 1) / thumbnail_columns;

const App = struct {
    view: enum { documents, thumbnails, settings } = .documents,
    clicks: u32 = 0,
    last_action: []const u8 = "nothing yet",
    selected_item: ?usize = 2,
    about_open: bool = false,
    display_name_bytes: [48]u8 = undefined,
    preferences: Preferences = undefined,
    preference_edits: u32 = 0,
    sources: AppSources = .{},
    loader: thumbnails.Loader,
    frames: u64 = 0,
    /// Producers' wakes of the window's event wait.
    wakes: std.atomic.Value(u32) = .init(0),

    fn initPreferences(app: *App) void {
        app.preferences = .{ .display_name = .init(&app.display_name_bytes, "Ada") };
    }

    fn waker(app: *App) zui.Waker {
        return .{ .context = app, .wakeFn = countWake };
    }

    fn countWake(context: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(context));
        _ = app.wakes.fetchAdd(1, .monotonic);
        zui_raylib.wake();
    }

    /// The loader: after `endFrame`, starts the loads the frame asked for.
    fn load(app: *App) void {
        app.loader.startWanted(&app.sources.thumbnails, app.waker());
    }
};

const DetailsState = struct { open: bool };

const ids = zui.ids(.{ "toolbar", "new", "open", "save", "documents_view", "thumbnails_view", "settings_view", "about", "sidebar", "content", "details_toggle", "hover_me", "dialog_close", "grid", "preferences", "save_preferences", "reset_preferences" });

fn label(ui: *Ui, content: []const u8, size: f32, color: zui.Color) void {
    ui.text(content, .{ .size = size, .color = color });
}

fn button(ui: *Ui, id: zui.Id, text: []const u8) bool {
    return widgets.button(ui, id, text, .{});
}

fn toolbar(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = ids.toolbar,
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(56) }, .padding = .symmetric(12, 8), .child_gap = 8, .child_alignment = .{ .y = .center } },
        .decoration = .{ .background = theme.panel, .border = .{ .color = theme.border, .widths = .{ .bottom = 1 } } },
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
    if (button(ui, ids.settings_view, "Settings")) app.view = .settings;
    if (button(ui, ids.about, "About")) app.about_open = true;
}

fn sidebar(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = ids.sidebar,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(260), .height = .grow }, .padding = .all(8), .child_gap = 4 },
        .decoration = .{ .background = theme.sidebar },
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
            .cursor = .pointer,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(36) }, .padding = .symmetric(12, 8), .child_alignment = .{ .y = .center } },
            .decoration = .{
                .background = if (selected) theme.accent else if (state == .hovered or state == .pressed) theme.button.get(.hovered) else null,
                .corner_radius = .all(4),
                .border = if (ui.focused(id)) .{ .color = theme.focus_ring, .widths = .all(1) } else null,
            },
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

    ui.text("zui + raylib", .{ .size = 40, .letter_spacing = 2, .color = theme.text });
    label(ui, "This window is laid out by zui and drawn by raylib. Every element is declared each frame as nested function calls; zui computes the layout and returns render commands, and the backend draws them. Resize the window to watch this paragraph re-wrap, scroll the list on the left with the wheel, and press Tab to move focus.", 20, theme.muted_text);

    ui.open(.{ .layout = .{ .child_gap = 12, .child_alignment = .{ .y = .center } } });
    const details = ui.state(ids.details_toggle, DetailsState);
    if (button(ui, ids.details_toggle, if (details.open) "Hide details" else "Show details")) details.open = !details.open;
    {
        ui.open(.{
            .id = ids.hover_me,
            .interactive = true,
            .cursor = .help,
            .layout = .{ .padding = .symmetric(14, 8) },
            .decoration = .{ .background = theme.button.get(ui.widgetState(ids.hover_me)), .corner_radius = .all(6) },
        });
        defer ui.close();
        label(ui, "Hover me", 20, theme.text);
        if (ui.hovered(ids.hover_me) and app.preferences.show_tooltips) {
            ui.open(.{
                .floating = .{ .anchor = .top_center, .attach_point = .bottom_center, .offset = .{ 0, 8 } },
                .layout = .{ .padding = .symmetric(10, 6) },
                .decoration = .{ .background = theme.focus_ring, .corner_radius = .all(4) },
            });
            label(ui, "A floating tooltip", 20, theme.background);
            ui.close();
        }
    }
    ui.close();

    if (details.open) {
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(16), .child_gap = 6 },
            .decoration = .{ .background = theme.panel, .corner_radius = .all(8), .border = .{ .color = theme.border, .widths = .all(1) } },
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

/// Only the rows near the visible part of the grid are declared, so only
/// their thumbnails are asked for. Keys that scroll away go unread, and
/// once unread long enough their loads are abandoned.
fn thumbnailGrid(ui: *Ui, app: *App) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 12 } });
    defer ui.close();

    const offset = ui.scrollOffset(ids.grid)[1];
    const visible_height = if (ui.rectOf(ids.grid)) |rect| rect.height else 600;
    const first_row: usize = @intFromFloat(@max(0, @floor(offset / thumbnail_pitch) - 1));
    const last_row: usize = @min(thumbnail_rows - 1, @as(usize, @intFromFloat(@floor((offset + visible_height) / thumbnail_pitch))) + 1);

    var stats_buffer: [192]u8 = undefined;
    const loader = &app.loader;
    const summary = std.fmt.bufPrint(&stats_buffer, "{d} thumbnails, rows {d}-{d} declared.  Loads started {d}, completed {d}, canceled {d}.  Wakes {d}, frames {d}", .{
        thumbnails.count,
        first_row + 1,
        last_row + 1,
        loader.started,
        loader.completed.load(.monotonic),
        loader.canceled.load(.monotonic),
        app.wakes.load(.monotonic),
        app.frames,
    }) catch "";
    label(ui, summary, 20, theme.muted_text);

    ui.open(.{ .id = ids.grid, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = thumbnail_gap }, .scroll = .{} });
    defer ui.close();

    const loads = ui.source(.thumbnails);
    if (first_row > 0) ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first_row)) * thumbnail_pitch - thumbnail_gap) } } });
    for (first_row..last_row + 1) |row| {
        ui.open(.{ .layout = .{ .child_gap = thumbnail_gap } });
        defer ui.close();
        for (0..thumbnail_columns) |column| {
            const index = row * thumbnail_columns + column;
            if (index >= thumbnails.count) break;
            thumbnailCell(ui, index, loads.get(@intCast(index)));
        }
    }
    const rows_below = thumbnail_rows - 1 - last_row;
    if (rows_below > 0) ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(rows_below)) * thumbnail_pitch - thumbnail_gap) } } });
}

fn thumbnailCell(ui: *Ui, index: usize, status: thumbnails.Loads.Status) void {
    ui.open(.{
        .id = .indexed("thumbnail", index),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(thumbnail_size), .height = .fixed(thumbnail_size) }, .padding = .all(8), .child_alignment = .{ .x = .center, .y = .center } },
        .decoration = .{ .background = theme.panel, .corner_radius = .all(6) },
    });
    defer ui.close();

    switch (status) {
        .idle, .running => label(ui, "loading", 20, theme.muted_text),
        .canceled => label(ui, "canceled", 20, theme.muted_text),
        .failed => label(ui, "failed", 20, theme.muted_text),
        .ready => |thumbnail| for (thumbnail.colors) |row| {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } } });
            defer ui.close();
            for (row) |color| ui.box(.{ .layout = .{ .sizing = .grow_both }, .decoration = .{ .background = color } });
        },
    }
}

fn settingsView(ui: *Ui, app: *App) void {
    ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(24), .child_gap = 24 } });
    defer ui.close();

    ui.open(.{
        .id = .of("preferences_scroll"),
        .scroll = .{},
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(620), .height = .grow }, .padding = .all(16), .child_gap = 12 },
        .decoration = .{ .background = theme.panel, .corner_radius = .all(8), .border = .{ .color = theme.border, .widths = .all(1) } },
    });
    label(ui, "Preferences", 30, theme.text);
    label(ui, "Generated by zui_reflect.inspector from the Preferences struct.", 20, theme.muted_text);
    if (zui_reflect.inspector(widgets, ui, ids.preferences, &app.preferences)) app.preference_edits += 1;
    ui.open(.{ .layout = .{ .child_gap = 8 } });
    if (widgets.button(ui, ids.save_preferences, "Save", .{})) app.preferences.times_saved += 1;
    if (widgets.button(ui, ids.reset_preferences, "Reset", .{})) {
        const times_saved = app.preferences.times_saved;
        app.initPreferences();
        app.preferences.times_saved = times_saved;
    }
    ui.close();
    ui.close();

    const preferences = &app.preferences;
    const card_color: zui.Color = switch (preferences.color_scheme) {
        .midnight => .rgb(0x20202a),
        .dusk => .rgb(0x3a2a3e),
        .high_contrast => .black,
    };
    ui.open(.{
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(20), .child_gap = 10 },
        .decoration = .{
            .background = card_color,
            .corner_radius = .all(8),
            .border = .{ .color = if (preferences.color_scheme == .high_contrast) .white else theme.border, .widths = .all(1) },
        },
    });
    defer ui.close();
    var buffer: [160]u8 = undefined;
    const greeting = std.fmt.bufPrint(&buffer, "Hello, {s}!", .{if (preferences.display_name.len == 0) "stranger" else preferences.display_name.slice()}) catch "Hello!";
    label(ui, greeting, @as(f32, @floatFromInt(preferences.font_size)) * preferences.interface_scale, theme.text);
    const autosave = if (preferences.autosave.enabled)
        std.fmt.bufPrint(buffer[80..], "Autosaving every {d} min", .{preferences.autosave.interval_minutes}) catch ""
    else
        "Autosave is off";
    label(ui, autosave, 20, theme.muted_text);
    var counts_buffer: [80]u8 = undefined;
    const counts = std.fmt.bufPrint(&counts_buffer, "Edits: {d}   Saves: {d}", .{ app.preference_edits, preferences.times_saved }) catch "";
    label(ui, counts, 20, theme.muted_text);
}

fn aboutDialog(ui: *Ui, app: *App) void {
    if (!app.about_open) return;
    if (ui.keyPressed(.escape)) app.about_open = false;

    ui.open(.{
        .interactive = true,
        .floating = .{ .attach_to = .root, .z = 10 },
        .layout = .{ .sizing = .grow_both, .child_alignment = .{ .x = .center, .y = .center } },
        .decoration = .{ .background = theme.overlay },
    });
    defer ui.close();
    ui.open(.{
        .focus_scope = true,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(420) }, .padding = .all(24), .child_gap = 14 },
        .decoration = .{ .background = theme.panel, .corner_radius = .all(10), .border = .{ .color = theme.border, .widths = .all(1) } },
    });
    defer ui.close();
    label(ui, "About", 30, theme.text);
    label(ui, "zui is an immediate-mode UI layout library for Zig. This dialog floats in its own layer and keeps tab focus inside it. Press Escape or Close.", 20, theme.muted_text);
    if (button(ui, ids.dialog_close, "Close")) app.about_open = false;
}

fn declare(ui: *Ui, app: *App) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = theme.background } });
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
        .settings => settingsView(ui, app),
    }
    aboutDialog(ui, app);
}

const Options = struct {
    screenshot_path: ?[:0]const u8 = null,
    about_open: bool = false,
    thumbnails: bool = false,
    settings: bool = false,
    hidden: bool = false,
    measure_idle: bool = false,
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
        } else if (std.mem.eql(u8, argument, "--settings")) {
            options.settings = true;
        } else if (std.mem.eql(u8, argument, "--hidden")) {
            options.hidden = true;
        } else if (std.mem.eql(u8, argument, "--measure-idle")) {
            options.hidden = true;
            options.measure_idle = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --screenshot <path>, --about, --thumbnails, --settings, --hidden or --measure-idle\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    const screenshot_mode = options.screenshot_path != null;

    c.SetConfigFlags(if (screenshot_mode or options.hidden) c.FLAG_WINDOW_HIDDEN else c.FLAG_WINDOW_RESIZABLE | c.FLAG_MSAA_4X_HINT);
    c.InitWindow(1100, 700, "zui + raylib");
    defer c.CloseWindow();
    c.SetTargetFPS(60);

    var text: zui_raylib.Text = .{};
    var ui = try Ui.init(init.gpa, io, &text);
    var renderer: zui_raylib.Renderer = .{ .text = &text };
    defer ui.deinit(init.gpa);

    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);
    app.* = .{
        .loader = .{ .io = io },
        .about_open = options.about_open,
        .view = if (options.thumbnails) .thumbnails else if (options.settings) .settings else .documents,
    };
    app.initPreferences();
    defer app.loader.deinit();

    var reader: zui_raylib.InputReader = .{};
    var pacer: zui_raylib.FramePacer = .{ .io = io };
    defer pacer.deinit();
    var host_requests: zui_raylib.HostRequestApplier = .{};

    const offscreen = if (screenshot_mode) c.LoadRenderTexture(c.GetScreenWidth(), c.GetScreenHeight()) else undefined;
    defer if (screenshot_mode) c.UnloadRenderTexture(offscreen);

    var idle_measurement: ?IdleMeasurement = if (options.measure_idle) .{ .launched_at = zui_raylib.now(io) } else null;

    while (!c.WindowShouldClose()) : (app.frames += 1) {
        const at = zui_raylib.now(io);
        const events = if (screenshot_mode) reader.eventsFor(at, screenshotSample(&ui, app)) else reader.read(at, .{});
        ui.beginFrame(&.{ .params = zui_raylib.windowParams(at), .events = events }, &app.sources);
        declare(&ui, app);
        if (idle_measurement) |*measurement| {
            if (measurement.reportAt(at, app)) |report| {
                std.debug.print("{f}\n", .{report});
                ui.release(ui.endFrame());
                break;
            }
            ui.requestFrameAt(measurement.nextCheckpoint());
        }
        const frame = ui.endFrame();

        if (screenshot_mode) c.BeginTextureMode(offscreen) else c.BeginDrawing();
        c.ClearBackground(.{ .r = theme.background.r, .g = theme.background.g, .b = theme.background.b, .a = 255 });
        try renderer.zuiSubmit(.library, frame);
        app.load();
        if (screenshot_mode) {
            c.EndTextureMode();
        } else {
            host_requests.apply(frame.requests());
            pacer.prepare(ui.nextFrame(&app.sources));
            c.EndDrawing();
        }
        zui_tracy.frameMark();
        ui.release(frame);

        if (screenshot_mode and screenshotReady(app)) {
            var image = c.LoadImageFromTexture(offscreen.texture);
            defer c.UnloadImage(image);
            c.ImageFlipVertical(&image);
            if (!c.ExportImage(image, options.screenshot_path.?.ptr)) return error.ScreenshotFailed;
            std.debug.print("saved {s}\n", .{options.screenshot_path.?});
            if (app.view == .thumbnails) std.debug.print("thumbnail loads: started {d}, completed {d}, canceled {d}; {d} wakes over {d} frames\n", .{
                app.loader.started,
                app.loader.completed.load(.monotonic),
                app.loader.canceled.load(.monotonic),
                app.wakes.load(.monotonic),
                app.frames + 1,
            });
            break;
        }
        if (screenshot_mode and app.view == .thumbnails) io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
}

/// `--measure-idle`: the CPU time the demo uses while idle, read by the
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
    fn reportAt(self: *IdleMeasurement, at: zui.Instant, app: *const App) ?Report {
        if (at.isBefore(self.nextCheckpoint())) return null;
        const checkpoint: Checkpoint = .{ .at = at, .cpu_nanoseconds = processCpuNanoseconds(), .frames = app.frames, .wakes = app.wakes.load(.monotonic) };
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

extern "kernel32" fn GetProcessTimes(process: std.os.windows.HANDLE, creation: *std.os.windows.FILETIME, exit: *std.os.windows.FILETIME, kernel: *std.os.windows.FILETIME, user: *std.os.windows.FILETIME) callconv(.winapi) std.os.windows.BOOL;

/// User and kernel time of every thread of this process.
fn processCpuNanoseconds() u64 {
    if (@import("builtin").os.tag == .windows) {
        var creation: std.os.windows.FILETIME = undefined;
        var exit: std.os.windows.FILETIME = undefined;
        var kernel: std.os.windows.FILETIME = undefined;
        var user: std.os.windows.FILETIME = undefined;
        if (GetProcessTimes(std.os.windows.GetCurrentProcess(), &creation, &exit, &kernel, &user) == .FALSE) return 0;
        const hundred_nanoseconds = fileTimeTicks(kernel) + fileTimeTicks(user);
        return hundred_nanoseconds * 100;
    }
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    return timevalNanoseconds(usage.utime) + timevalNanoseconds(usage.stime);
}

fn fileTimeTicks(time: std.os.windows.FILETIME) u64 {
    return @as(u64, time.dwHighDateTime) << 32 | time.dwLowDateTime;
}

fn timevalNanoseconds(time: anytype) u64 {
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.usec)) * std.time.ns_per_us;
}

fn centerOf(rect: zui.Rect) [2]f32 {
    return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
}

/// The input a screenshot is taken with, known from the previous frame's
/// layout.
fn screenshotSample(ui: *const Ui, app: *const App) zui.InputSampler.Sample {
    var sample: zui.InputSampler.Sample = .{};
    switch (app.view) {
        // Rest the pointer on "Hover me" so the screenshot shows hover
        // state and the tooltip.
        .documents => sample.pointer = if (ui.rectOf(ids.hover_me)) |rect| centerOf(rect) else null,
        // Scroll far down once loads are underway, so the rows that leave
        // the screen go unread and their loads are abandoned.
        .thumbnails => {
            sample.pointer = if (ui.rectOf(ids.grid)) |rect| centerOf(rect) else null;
            if (app.frames == 5) sample.wheel = .{ 0, 3000 };
        },
        // Click the color scheme dropdown open, then rest the pointer on its
        // last option so it shows hover state.
        .settings => {
            const dropdown = ids.preferences.child("color_scheme");
            const target = if (app.frames < 3) dropdown else dropdown.indexedChild("option", 2);
            sample.pointer = if (ui.rectOf(target)) |rect| centerOf(rect) else null;
            if (app.frames == 1) sample.buttons = .initOne(.primary);
        },
    }
    return sample;
}

/// Documents: three frames (lay out, hover, show the tooltip). Thumbnails:
/// once some loads have finished and some scrolled-away ones were
/// abandoned. Settings: once the dropdown is open with an option hovered.
fn screenshotReady(app: *const App) bool {
    return switch (app.view) {
        .documents => app.frames == 2,
        .thumbnails => (app.loader.completed.load(.monotonic) >= 20 and app.loader.canceled.load(.monotonic) >= 1) or app.frames > 600,
        .settings => app.frames == 5,
    };
}
