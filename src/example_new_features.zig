//! Izo Example - New Features Demo
//!
//! This file demonstrates the planned new features:
//! 1. Enhanced error handling
//! 2. Default value support
//! 3. Array element mapping
//! 4. Performance optimizations

const std = @import("std");
const izo = @import("izomorph");

// ==================== Example 1: Default Values ====================

const PersonWithDefaults = struct {
    name: []const u8,
    age: u32,
    country: []const u8,
};

// Default value support structure (to be fully implemented)
const PersonDefaultsMapper = izo.Mapper(PersonWithDefaults, .{
    .country = .{ .default_value = .{ .string = "USA" } },
});

// ==================== Example 2: Enhanced Error Handling ====================

test "error handling module exists" {
    // Verify error module is exported
    _ = izo.errors.SerializeError;
    _ = izo.errors.ErrorContext;
    _ = izo.errors.ErrorHandler;
}

// ==================== Example 3: Performance Optimization ====================

test "arena allocator example" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = izo.Mapper(Person, .{});

    // Use arena allocator for batch operations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_str = "{\"name\":\"Alice\",\"age\":30}";
    const person = try izo.json.decode(arena.allocator(), Person, PersonMapper, json_str);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
    // All allocations freed at once when arena deinits
}

// ==================== Integration Demo ====================

test "roundtrip with defaults" {
    const allocator = std.testing.allocator;

    const Config = struct {
        name: []const u8,
        port: u32,
    };

    const ConfigMapper = izo.Mapper(Config, .{});

    // Encode
    const config = Config{
        .name = "MyApp",
        .port = 8080,
    };

    const json = try izo.json.encode(allocator, config, ConfigMapper, .{});
    defer allocator.free(json);

    // Decode
    const decoded = try izo.json.decode(allocator, ConfigMapper, json);

    try std.testing.expectEqualStrings(config.name, decoded.name);
    try std.testing.expectEqual(config.port, decoded.port);
}
