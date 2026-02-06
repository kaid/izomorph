//! Izo JSON Encoder - Implementation based on std.json
//!
//! Leverages Zig's mature standard library JSON implementation for reliable serialization.
//! Field mapping is achieved through Mapper-generated Adapters.

const std = @import("std");

/// JSON encoding error set
pub const Error = std.json.Stringify.Error || std.mem.Allocator.Error;

/// Encoding options
///
/// Wraps std.json.Stringify.Options and adds Izo-specific options
pub const EncodeOptions = struct {
    /// Enable pretty printing
    pretty: bool = false,
    /// Indent size (effective when pretty=true)
    indent_size: u8 = 2,

    /// Convert to std.json options
    pub fn toStdOptions(self: EncodeOptions) std.json.Stringify.Options {
        return .{
            .whitespace = if (self.pretty) .indent_2 else .minified,
        };
    }
};

/// Encode a value to JSON string
///
/// Usage example:
/// ```zig
/// const Person = struct { name: []const u8, age: u32 };
/// const PersonMapper = izo.Mapper(Person, .{ .name = .{ .alias = "person_name" } });
/// const json = try izo.json.encode(allocator, person, PersonMapper, .{});
/// defer allocator.free(json);
/// ```
pub fn encode(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime MapperType: type,
    options: EncodeOptions,
) Error![]const u8 {
    // Use the adapter module for encoding
    return try @import("adapter.zig").encodeWithMapper(allocator, value, MapperType, options.toStdOptions());
}

// ==================== Tests ====================

const mapper = @import("../mapper.zig");

test "encode - basic types" {
    const allocator = std.testing.allocator;

    // Integer
    const int_result = try std.json.Stringify.valueAlloc(allocator, @as(i32, 42), .{});
    defer allocator.free(int_result);
    try std.testing.expectEqualStrings("42", int_result);

    // Float
    const float_result = try std.json.Stringify.valueAlloc(allocator, @as(f64, 3.14), .{});
    defer allocator.free(float_result);
    try std.testing.expectEqualStrings("3.14", float_result);

    // Boolean
    const bool_true = try std.json.Stringify.valueAlloc(allocator, true, .{});
    defer allocator.free(bool_true);
    try std.testing.expectEqualStrings("true", bool_true);

    const bool_false = try std.json.Stringify.valueAlloc(allocator, false, .{});
    defer allocator.free(bool_false);
    try std.testing.expectEqualStrings("false", bool_false);
}

test "encode - string" {
    const allocator = std.testing.allocator;

    const result = try std.json.Stringify.valueAlloc(allocator, "hello", .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "encode - simple struct" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const person = Person{
        .name = "Alice",
        .age = 30,
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", result);
}

test "encode - struct with alias" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const person = Person{
        .name = "Bob",
        .age = 25,
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output: name mapped to person_name
    try std.testing.expectEqualStrings("{\"person_name\":\"Bob\",\"age\":25}", result);
}

test "encode - struct with skip" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        secret: []const u8,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .secret = .skip,
    });

    const person = Person{
        .name = "Charlie",
        .secret = "password123",
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output: secret field skipped
    try std.testing.expectEqualStrings("{\"name\":\"Charlie\"}", result);
}

test "encode - array" {
    const allocator = std.testing.allocator;

    const arr = [3]i32{ 1, 2, 3 };
    const result = try std.json.Stringify.valueAlloc(allocator, arr, .{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[1,2,3]", result);
}

test "encode - optional" {
    const allocator = std.testing.allocator;

    const some_value: ?i32 = 42;
    const result1 = try std.json.Stringify.valueAlloc(allocator, some_value, .{});
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("42", result1);

    const null_value: ?i32 = null;
    const result2 = try std.json.Stringify.valueAlloc(allocator, null_value, .{});
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("null", result2);
}

test "encode - with pretty printing" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const person = Person{
        .name = "Alice",
        .age = 30,
    };

    const result = try encode(allocator, person, PersonMapper, .{ .pretty = true });
    defer allocator.free(result);

    // Verify pretty print format
    const expected = "{\n  \"name\": \"Alice\",\n  \"age\": 30\n}";
    try std.testing.expectEqualStrings(expected, result);
}

test "encode - nested struct with mapping" {
    const allocator = std.testing.allocator;

    const Address = struct {
        street: []const u8,
        city: []const u8,
        zip: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    // Define Mapper for nested struct
    const AddressMapper = mapper.Mapper(Address, .{
        .street = .{ .alias = "road" },
        .zip = .skip,
    });

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "full_name" },
        .address = .{ .nested = AddressMapper },
    });

    const person = Person{
        .name = "Alice",
        .address = .{
            .street = "123 Main St",
            .city = "New York",
            .zip = "10001",
        },
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"full_name\":\"Alice\",\"address\":{\"road\":\"123 Main St\",\"city\":\"New York\"}}", result);
}

test "encode - struct with array" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        hobbies: []const []const u8,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .hobbies = .{ .alias = "interests" },
    });

    const person = Person{
        .name = "Bob",
        .hobbies = &.{ "reading", "gaming", "coding" },
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"name\":\"Bob\",\"interests\":[\"reading\",\"gaming\",\"coding\"]}", result);
}

test "encode - deeply nested structure" {
    const allocator = std.testing.allocator;

    const Hobby = struct {
        name: []const u8,
        years: u32,
    };

    const Address = struct {
        street: []const u8,
        hobbies: []const Hobby,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const person = Person{
        .name = "Charlie",
        .address = .{
            .street = "789 Pine Rd",
            .hobbies = &.{
                .{ .name = "reading", .years = 5 },
                .{ .name = "gaming", .years = 3 },
            },
        },
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"person_name\":\"Charlie\",\"address\":{\"street\":\"789 Pine Rd\",\"hobbies\":[{\"name\":\"reading\",\"years\":5},{\"name\":\"gaming\",\"years\":3}]}}", result);
}

test "encode - struct with skip in nested" {
    const allocator = std.testing.allocator;

    const Address = struct {
        street: []const u8,
        password: []const u8,
        city: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
        secret: []const u8,
    };

    // Define Mapper for nested struct, skip password field
    const AddressMapper = mapper.Mapper(Address, .{
        .password = .skip,
    });

    const PersonMapper = mapper.Mapper(Person, .{
        .secret = .skip,
        .address = .{ .alias = "location", .nested = AddressMapper },
    });

    const person = Person{
        .name = "Dave",
        .address = .{
            .street = "456 Oak Ave",
            .password = "secret123",
            .city = "Boston",
        },
        .secret = "my_secret",
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"name\":\"Dave\",\"location\":{\"street\":\"456 Oak Ave\",\"city\":\"Boston\"}}", result);
}

test "encode - multiple aliases" {
    const allocator = std.testing.allocator;

    const Person = struct {
        first_name: []const u8,
        last_name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .first_name = .{ .alias = "firstName" },
        .last_name = .{ .alias = "lastName" },
    });

    const person = Person{
        .first_name = "John",
        .last_name = "Doe",
        .age = 35,
    };

    const result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(result);

    // Verify complete JSON output
    try std.testing.expectEqualStrings("{\"firstName\":\"John\",\"lastName\":\"Doe\",\"age\":35}", result);
}
