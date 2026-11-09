const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy = b.option(bool, "zui-tracy", "Link Tracy's client, so the demo traces zui's zones into the Tracy profiler") orelse false;

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy });
    const raylib_dependency = b.dependency("raylib", .{ .target = target, .optimize = optimize });
    const zui_module = zui_dependency.module("zui");
    const zui_async_module = zui_dependency.module("zui_async");
    const zui_testing_module = zui_dependency.module("zui_testing");
    const raylib_module = raylib_dependency.module("raylib");

    const backend_module = b.addModule("zui_raylib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_app", .module = zui_dependency.module("zui_app") },
            .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
            .{ .name = "zui_reflect", .module = zui_dependency.module("zui_reflect") },
            .{ .name = "zui_async", .module = zui_async_module },
            .{ .name = "zui_tracy", .module = zui_dependency.module("zui_tracy") },
            .{ .name = "raylib", .module = raylib_module },
            .{ .name = "rlgl", .module = raylib_dependency.module("rlgl") },
        },
    });

    const test_step = b.step("test", "Run the backend's unit tests and the demo's thumbnail tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = backend_module })).step);
    const thumbnail_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/thumbnails.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_async", .module = zui_async_module },
            .{ .name = "zui_testing", .module = zui_testing_module },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(thumbnail_tests).step);

    // Needs a display, which `test` does not: on Linux CI it runs under Xvfb.
    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_raylib", .module = backend_module },
            .{ .name = "zui_testing", .module = zui_testing_module },
        },
    }) });
    b.step("conformance", "Run zui's renderer and host suites against the renderer and the host, in hidden windows").dependOn(&b.addRunArtifact(conformance_tests).step);

    const demo = b.addExecutable(.{
        .name = "zui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_raylib", .module = backend_module },
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_async", .module = zui_async_module },
                .{ .name = "zui_testing", .module = zui_testing_module },
            },
        }),
    });
    if (target.result.os.tag == .windows) demo.subsystem = .windows;
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo application (`-- --screenshot demo.png` renders offscreen and exits)").dependOn(&run_demo.step);

    const check_step = b.step("check", "Compile the backend, the demo and the renderer suite without producing output");
    check_step.dependOn(&demo.step);
    check_step.dependOn(&conformance_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}
