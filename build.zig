const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const raylib_dependency = b.dependency("raylib", .{ .target = target, .optimize = optimize });
    const zui_module = zui_dependency.module("zui");
    const raylib_module = raylib_dependency.module("raylib");

    const backend_module = b.addModule("zui_raylib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "raylib", .module = raylib_module },
        },
    });

    const unit_tests = b.addTest(.{ .root_module = backend_module });
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const demo = b.addExecutable(.{
        .name = "zui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui_raylib", .module = backend_module }},
        }),
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo application (`-- --screenshot demo.png` renders offscreen and exits)").dependOn(&run_demo.step);

    b.step("check", "Compile the backend and the demo without producing output").dependOn(&demo.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}
