//! Izo JSON Decoder - Implementation based on std.json
//!
//! Leverages Zig's mature standard library JSON implementation for reliable deserialization.
//! Field mapping is achieved through Mapper (alias resolution, field skipping, etc.).

const std = @import("std");

/// JSON decoding error set
pub const Error = std.json.ParseError(std.json.Scanner) || error{MissingField};

/// Decoding options
pub const DecodeOptions = struct {
    /// Behavior when encountering unknown fields
    ignore_unknown_fields: bool = true,
    /// Behavior when encountering duplicate fields
    duplicate_field_behavior: enum {
        use_first,
        @"error",
        use_last,
    } = .use_last,
};

/// Decode JSON string to specified type
///
/// Usage example:
/// ```zig
/// const Person = struct { name: []const u8, age: u32 };
/// const PersonMapper = izo.Mapper(Person, .{ .name = .{ .alias = "person_name" } });
/// const person = try izo.json.decode(allocator, Person, PersonMapper, json_str);
/// ```
pub fn decode(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime MapperType: type,
    json_str: []const u8,
) Error!T {
    // Use the adapter module for decoding
    return try @import("adapter.zig").decodeWithMapper(allocator, T, MapperType, json_str);
}

// ==================== Tests ====================

const mapper = @import("../mapper.zig");

test "decode - simple struct" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const json_str = "{\"name\":\"Alice\",\"age\":30}";
    const person = try decode(allocator, Person, PersonMapper, json_str);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
}

test "decode - struct with alias" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    // JSON uses alias
    const json_str = "{\"person_name\":\"Bob\",\"age\":25}";
    const person = try decode(allocator, Person, PersonMapper, json_str);

    try std.testing.expectEqualStrings("Bob", person.name);
    try std.testing.expectEqual(@as(u32, 25), person.age);
}

test "decode - ignore unknown fields" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    // JSON contains unknown fields
    const json_str = "{\"name\":\"Charlie\",\"age\":35,\"extra\":\"ignored\"}";
    const person = try decode(allocator, Person, PersonMapper, json_str);

    try std.testing.expectEqualStrings("Charlie", person.name);
    try std.testing.expectEqual(@as(u32, 35), person.age);
}

test "decode - nested struct" {
    const allocator = std.testing.allocator;

    const Address = struct {
        street: []const u8,
        city: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    const AddressMapper = mapper.Mapper(Address, .{
        .street = .{ .alias = "road" },
    });

    const PersonMapper = mapper.Mapper(Person, .{
        .address = .{ .nested = AddressMapper },
    });

    const json_str = "{\"name\":\"Dave\",\"address\":{\"road\":\"123 Main St\",\"city\":\"Boston\"}}";
    const person = try decode(allocator, Person, PersonMapper, json_str);

    try std.testing.expectEqualStrings("Dave", person.name);
    try std.testing.expectEqualStrings("123 Main St", person.address.street);
    try std.testing.expectEqualStrings("Boston", person.address.city);
}

test "decode - roundtrip encode/decode" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    // Encode
    const person = Person{ .name = "Eve", .age = 28 };
    const encoded = try @import("encode.zig").encode(allocator, person, PersonMapper, .{});
    defer allocator.free(encoded);

    // Decode
    const decoded = try decode(allocator, Person, PersonMapper, encoded);

    try std.testing.expectEqualStrings(person.name, decoded.name);
    try std.testing.expectEqual(person.age, decoded.age);
}

test "decode - array with element mapper" {
    const allocator = std.testing.allocator;

    const Hobby = struct {
        name: []const u8,
        years: u32,
    };

    const Person = struct {
        name: []const u8,
        hobbies: []const Hobby,
    };

    // Define element mapper for hobbies
    const HobbyMapper = mapper.Mapper(Hobby, .{
        .name = .{ .alias = "hobby_name" },
    });

    const PersonMapper = mapper.Mapper(Person, .{
        .hobbies = .{ .element_mapper = HobbyMapper },
    });

    // JSON with aliased hobby names
    const json_str = "{\"name\":\"Alice\",\"hobbies\":[{\"hobby_name\":\"reading\",\"years\":5},{\"hobby_name\":\"gaming\",\"years\":3}]}";
    const person = try decode(allocator, Person, PersonMapper, json_str);
    defer allocator.free(person.hobbies);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(usize, 2), person.hobbies.len);
    try std.testing.expectEqualStrings("reading", person.hobbies[0].name);
    try std.testing.expectEqual(@as(u32, 5), person.hobbies[0].years);
    try std.testing.expectEqualStrings("gaming", person.hobbies[1].name);
    try std.testing.expectEqual(@as(u32, 3), person.hobbies[1].years);
}
