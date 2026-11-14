const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tracy = b.option(bool, "zui-tracy", "Link Tracy's client, so the demo traces zui's zones into the Tracy profiler") orelse false;

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy });
    const raylib_dependency = b.dependency("raylib", .{ .target = target, .optimize = optimize });
    const zui_module = zui_dependency.module("zui");
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
            .{ .name = "zui_async", .module = zui_dependency.module("zui_async") },
            .{ .name = "zui_tracy", .module = zui_dependency.module("zui_tracy") },
            .{ .name = "raylib", .module = raylib_module },
            .{ .name = "rlgl", .module = raylib_dependency.module("rlgl") },
        },
    });

    moveSystemLibrariesOntoModule(raylib_dependency.artifact("raylib"), backend_module);

    const backend_tests = b.addTest(.{ .root_module = backend_module });
    linkThroughLlvmOnLinux(backend_tests);
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(backend_tests).step);

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
    linkThroughLlvmOnLinux(conformance_tests);
    b.step("conformance", "Run zui's renderer and host suites against the renderer and the host, in hidden windows").dependOn(&b.addRunArtifact(conformance_tests).step);

    const demo_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui_raylib", .module = backend_module },
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
    };
    const demo = b.addExecutable(.{
        .name = "zui-demo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/demo.zig"), .target = target, .optimize = optimize, .imports = demo_imports }),
    });
    if (target.result.os.tag == .windows) demo.subsystem = .windows;
    linkThroughLlvmOnLinux(demo);
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the tour (`-- --frames 900 --cycle 40` visits every screen and quits)").dependOn(&run_demo.step);

    const tour_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("examples/tour_test.zig"), .target = target, .optimize = optimize, .imports = demo_imports }) });
    linkThroughLlvmOnLinux(tour_tests);
    b.step("test-tour", "Declare every screen of the tour headlessly; fail if one exceeds its limits or does not fit the default window").dependOn(&b.addRunArtifact(tour_tests).step);

    const check_step = b.step("check", "Compile the backend, the tour, its tests and the renderer suite without producing output");
    check_step.dependOn(&demo.step);
    check_step.dependOn(&tour_tests.step);
    check_step.dependOn(&conformance_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// Zig archives the shared libraries a static library links (raylib's GL
/// and X11) into it, and LLD's warning about those members fails the
/// link. Linked from `module` instead, they reach every artifact that
/// imports it and stay out of the archive.
fn moveSystemLibrariesOntoModule(library: *std.Build.Step.Compile, module: *std.Build.Module) void {
    const link_objects = &library.root_module.link_objects;
    var index: usize = 0;
    while (index < link_objects.items.len) {
        switch (link_objects.items[index]) {
            .system_lib => |system_library| {
                module.linkSystemLibrary(system_library.name, .{});
                _ = link_objects.orderedRemove(index);
            },
            else => index += 1,
        }
    }
}
