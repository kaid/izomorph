const std = @import("std");

/// Build configuration for Izomorph library
///
/// This library provides structure-preserving serialization for Zig,
/// supporting JSON encoding/decoding with field mapping.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    // Define the izomorph module
    const mod = b.addModule("izomorph", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Test runner for the module
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test step
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);
}
