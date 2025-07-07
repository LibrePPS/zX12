const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add the zX12 dependency
    // This assumes you've run: zig fetch --save "git+https://github.com/LibrePPS/zX12#main"
    const zx12_dep = b.dependency("zx12", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the zX12 module
    const zx12_module = zx12_dep.module("zx12");

    // Create the example executable
    const exe = b.addExecutable(.{
        .name = "zx12_example",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the zX12 module to the executable
    exe.root_module.addImport("zx12", zx12_module);

    // Install the executable
    b.installArtifact(exe);

    // Build and run with `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
