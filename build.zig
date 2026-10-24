const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ssftool = b.addExecutable(.{
        .name = "ssftool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(ssftool);

    const pfm2specdata = b.addExecutable(.{
        .name = "pfm2specdata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pfm2specdata.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(pfm2specdata);

    const run_step = b.step("run", "Run ssftool");
    const run_cmd = b.addRunArtifact(ssftool);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
