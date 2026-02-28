//! Izo JSON Decoder - Implementation based on std.json
//!
//! Leverages Zig's mature standard library JSON implementation for reliable deserialization.
//! Field mapping is achieved through Mapper (alias resolution, field skipping, etc.).

const std = @import("std");

/// JSON decoding error set for complete input
pub const Error = std.json.ParseError(std.json.Scanner) || error{MissingField};

/// JSON decoding error set for streaming from Io.Reader
pub const ReaderError = std.json.ParseError(std.json.Reader) || error{MissingField};

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
/// const person = try izo.json.decode(allocator, PersonMapper, json_str);
/// ```
pub fn decode(
    allocator: std.mem.Allocator,
    comptime MapperType: type,
    json_str: []const u8,
) Error!MapperType.TargetType {
    // Use the adapter module for decoding
    return try @import("adapter.zig").decodeWithMapper(allocator, MapperType, json_str);
}

/// Decode JSON from an Io.Reader (streaming)
///
/// This function allows decoding JSON directly from any reader without loading
/// the entire input into memory first. Useful for reading from network sockets,
/// files, or other streaming sources.
///
/// The Reader internally handles buffering and automatically refills when needed.
/// Memory usage is O(nesting depth) rather than O(document size).
///
/// Usage example:
/// ```zig
/// var file = try std.fs.cwd().openFile("data.json", .{});
/// defer file.close();
/// var reader = file.reader();
/// const person = try izo.json.decodeFromReader(allocator, PersonMapper, &reader);
/// ```
///
/// For HTTP request body parsing:
/// ```zig
/// var request_reader: std.Io.Reader = request.bodyReader();
/// const body = try izo.json.decodeFromReader(arena.allocator(), RequestMapper, &request_reader);
/// ```
pub fn decodeFromReader(
    allocator: std.mem.Allocator,
    comptime MapperType: type,
    reader: *std.Io.Reader,
) ReaderError!MapperType.TargetType {
    return try @import("adapter.zig").decodeWithReader(allocator, MapperType, reader);
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
    const person = try decode(allocator, PersonMapper, json_str);

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
    const person = try decode(allocator, PersonMapper, json_str);

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
    const person = try decode(allocator, PersonMapper, json_str);

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
        .address = .{ .strategy = .{ .nested = AddressMapper } },
    });

    const json_str = "{\"name\":\"Dave\",\"address\":{\"road\":\"123 Main St\",\"city\":\"Boston\"}}";
    const person = try decode(allocator, PersonMapper, json_str);

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
    const decoded = try decode(allocator, PersonMapper, encoded);

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
    const person = try decode(allocator, PersonMapper, json_str);
    defer allocator.free(person.hobbies);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(usize, 2), person.hobbies.len);
    try std.testing.expectEqualStrings("reading", person.hobbies[0].name);
    try std.testing.expectEqual(@as(u32, 5), person.hobbies[0].years);
    try std.testing.expectEqualStrings("gaming", person.hobbies[1].name);
    try std.testing.expectEqual(@as(u32, 3), person.hobbies[1].years);
}

test "decode - with arena allocator" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    // Use arena allocator for batch operations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_str = "{\"name\":\"Alice\",\"age\":30}";
    const person = try decode(arena.allocator(), PersonMapper, json_str);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
    // All allocations freed at once when arena deinits
}

// ==================== decodeFromReader Tests ====================

test "decodeFromReader - basic struct" {
    const gpa = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const json_str = "{\"name\":\"Alice\",\"age\":30}";
    var reader: std.Io.Reader = .fixed(json_str);

    // Use arena for automatic cleanup
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
}

test "decodeFromReader - struct with alias" {
    const gpa = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const json_str = "{\"person_name\":\"Bob\",\"age\":25}";
    var reader: std.Io.Reader = .fixed(json_str);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader);

    try std.testing.expectEqualStrings("Bob", person.name);
    try std.testing.expectEqual(@as(u32, 25), person.age);
}

test "decodeFromReader - ignore unknown fields" {
    const gpa = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const json_str = "{\"name\":\"Charlie\",\"age\":35,\"extra\":\"ignored\"}";
    var reader: std.Io.Reader = .fixed(json_str);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader);

    try std.testing.expectEqualStrings("Charlie", person.name);
    try std.testing.expectEqual(@as(u32, 35), person.age);
}

test "decodeFromReader - nested struct" {
    const gpa = std.testing.allocator;

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
        .address = .{ .strategy = .{ .nested = AddressMapper } },
    });

    const json_str = "{\"name\":\"Dave\",\"address\":{\"road\":\"123 Main St\",\"city\":\"Boston\"}}";
    var reader: std.Io.Reader = .fixed(json_str);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader);

    try std.testing.expectEqualStrings("Dave", person.name);
    try std.testing.expectEqualStrings("123 Main St", person.address.street);
    try std.testing.expectEqualStrings("Boston", person.address.city);
}

test "decodeFromReader - parity with decode" {
    const gpa = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const json_str = "{\"person_name\":\"Eve\",\"age\":28}";

    // Method 1: decode() with complete string (using arena)
    var arena1 = std.heap.ArenaAllocator.init(gpa);
    defer arena1.deinit();
    const person1 = try decode(arena1.allocator(), PersonMapper, json_str);

    // Method 2: decodeFromReader() with Io.Reader (using arena)
    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    var reader: std.Io.Reader = .fixed(json_str);
    const person2 = try decodeFromReader(arena2.allocator(), PersonMapper, &reader);

    // Both should produce identical results
    try std.testing.expectEqualStrings(person1.name, person2.name);
    try std.testing.expectEqual(person1.age, person2.age);
}
