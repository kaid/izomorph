//! Izo JSON Decoder - Implementation based on std.json
//!
//! Leverages Zig's mature standard library JSON implementation for reliable deserialization.
//! Field mapping is achieved through Mapper (alias resolution, field skipping, etc.).

const std = @import("std");
const DuplicateFieldBehavior = @FieldType(std.json.ParseOptions, "duplicate_field_behavior");

/// JSON decoding error set for complete input
pub const Error = std.json.ParseError(std.json.Scanner) || error{MissingField};

/// JSON decoding error set for streaming from Io.Reader
pub const ReaderError = std.json.ParseError(std.json.Reader) || error{MissingField};

/// Decoding options
pub const DecodeOptions = struct {
    /// Behavior when encountering unknown fields
    ignore_unknown_fields: bool = true,
    /// Behavior when encountering duplicate fields
    duplicate_field_behavior: DuplicateFieldBehavior = .use_last,
};

/// Decode JSON string to specified type
///
/// Usage example:
/// ```zig
/// const Person = struct { name: []const u8, age: u32 };
/// const PersonMapper = izo.Mapper(Person, .{ .name = .{ .alias = "person_name" } });
/// const person = try izo.json.decode(allocator, PersonMapper, json_str, .{});
/// ```
pub fn decode(
    allocator: std.mem.Allocator,
    comptime CodecType: type,
    json_str: []const u8,
    options: DecodeOptions,
) Error!CodecType.TargetType {
    const parse_options = std.json.ParseOptions{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .duplicate_field_behavior = options.duplicate_field_behavior,
        .max_value_len = json_str.len,
        .allocate = .alloc_if_needed,
    };

    // Use the adapter module for decoding
    return try @import("adapter.zig").decodeWithMapper(allocator, CodecType, json_str, parse_options);
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
/// const person = try izo.json.decodeFromReader(allocator, PersonMapper, &reader, .{});
/// ```
///
/// For HTTP request body parsing:
/// ```zig
/// var request_reader: std.Io.Reader = request.bodyReader();
/// const body = try izo.json.decodeFromReader(arena.allocator(), RequestMapper, &request_reader, .{});
/// ```
pub fn decodeFromReader(
    allocator: std.mem.Allocator,
    comptime CodecType: type,
    reader: *std.Io.Reader,
    options: DecodeOptions,
) ReaderError!CodecType.TargetType {
    const parse_options = std.json.ParseOptions{
        .ignore_unknown_fields = options.ignore_unknown_fields,
        .duplicate_field_behavior = options.duplicate_field_behavior,
        .max_value_len = std.json.default_max_value_len,
        .allocate = .alloc_always,
    };

    return try @import("adapter.zig").decodeWithReader(allocator, CodecType, reader, parse_options);
}

// ==================== Tests ====================

const mapper = @import("../mapper.zig");
const Root = @import("root_codec.zig").Root;

test "decode - simple struct" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const json_str = "{\"name\":\"Alice\",\"age\":30}";
    const person = try decode(allocator, PersonMapper, json_str, .{});

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
    const person = try decode(allocator, PersonMapper, json_str, .{});

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
    const person = try decode(allocator, PersonMapper, json_str, .{});

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
    const person = try decode(allocator, PersonMapper, json_str, .{});

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
    const decoded = try decode(allocator, PersonMapper, encoded, .{});

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
    const person = try decode(allocator, PersonMapper, json_str, .{});
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
    const person = try decode(arena.allocator(), PersonMapper, json_str, .{});

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

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader, .{});

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

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader, .{});

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

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader, .{});

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

    const person = try decodeFromReader(arena.allocator(), PersonMapper, &reader, .{});

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
    const person1 = try decode(arena1.allocator(), PersonMapper, json_str, .{});

    // Method 2: decodeFromReader() with Io.Reader (using arena)
    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    var reader: std.Io.Reader = .fixed(json_str);
    const person2 = try decodeFromReader(arena2.allocator(), PersonMapper, &reader, .{});

    // Both should produce identical results
    try std.testing.expectEqualStrings(person1.name, person2.name);
    try std.testing.expectEqual(person1.age, person2.age);
}

test "decode - options: unknown fields error when disabled" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});
    const json_str = "{\"name\":\"Alice\",\"age\":30,\"extra\":\"not-allowed\"}";

    try std.testing.expectError(error.UnknownField, decode(allocator, PersonMapper, json_str, .{
        .ignore_unknown_fields = false,
    }));
}

test "decode - root array with element mapper" {
    const allocator = std.testing.allocator;

    const Event = struct {
        id: u32,
        score: i32,
    };

    const EventMapper = mapper.Mapper(Event, .{
        .id = .{ .alias = "eventId" },
    });
    const EventsRoot = Root.array(EventMapper);

    const json_str = "[{\"eventId\":1,\"score\":10},{\"eventId\":2,\"score\":20}]";
    const events = try decode(allocator, EventsRoot, json_str, .{});
    defer allocator.free(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u32, 1), events[0].id);
    try std.testing.expectEqual(@as(i32, 20), events[1].score);

    const encoded = try @import("encode.zig").encode(allocator, events, EventsRoot, .{});
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(json_str, encoded);
}

test "decode - root map with value mapper" {
    const allocator = std.testing.allocator;

    const Event = struct {
        id: u32,
        score: i32,
    };

    const EventMapper = mapper.Mapper(Event, .{
        .id = .{ .alias = "eventId" },
    });
    const EventsByNameRoot = Root.map(EventMapper);

    const json_str = "{\"first\":{\"eventId\":1,\"score\":10},\"second\":{\"eventId\":2,\"score\":20}}";
    var by_name = try decode(allocator, EventsByNameRoot, json_str, .{});
    defer by_name.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), by_name.get("first").?.id);
    try std.testing.expectEqual(@as(i32, 20), by_name.get("second").?.score);
}

test "decode - root mapOf plain values" {
    const allocator = std.testing.allocator;
    const QuotaRoot = Root.mapOf(i64);

    var quotas = try decode(allocator, QuotaRoot, "{\"free\":1000,\"pro\":10000}", .{});
    defer quotas.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 1000), quotas.get("free").?);
    try std.testing.expectEqual(@as(i64, 10000), quotas.get("pro").?);
}

test "decode - root map duplicate field behavior use_first" {
    const allocator = std.testing.allocator;
    const QuotaRoot = Root.mapOf(i64);

    var quotas = try decode(allocator, QuotaRoot, "{\"tier\":1,\"tier\":2}", .{
        .duplicate_field_behavior = .use_first,
    });
    defer quotas.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 1), quotas.get("tier").?);
}

test "decode - root map duplicate field behavior error" {
    const allocator = std.testing.allocator;
    const QuotaRoot = Root.mapOf(i64);

    try std.testing.expectError(error.DuplicateField, decode(allocator, QuotaRoot, "{\"tier\":1,\"tier\":2}", .{
        .duplicate_field_behavior = .@"error",
    }));
}

test "decodeFromReader - root arrayOf plain values" {
    const allocator = std.testing.allocator;
    const IdsRoot = Root.arrayOf(u32);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var reader: std.Io.Reader = .fixed("[1,2,3]");
    const ids = try decodeFromReader(arena.allocator(), IdsRoot, &reader, .{});

    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try std.testing.expectEqual(@as(u32, 1), ids[0]);
    try std.testing.expectEqual(@as(u32, 3), ids[2]);
}

test "decode - root mapOrderedOf preserves input order and encode order" {
    const allocator = std.testing.allocator;
    const OrderedQuotaRoot = Root.mapOrderedOf(i64);
    const json_str = "{\"b\":2,\"a\":1}";

    var quotas = try decode(allocator, OrderedQuotaRoot, json_str, .{});
    defer quotas.deinit(allocator);

    var it = quotas.iterator();
    const first = it.next().?;
    const second = it.next().?;
    try std.testing.expectEqualStrings("b", first.key_ptr.*);
    try std.testing.expectEqualStrings("a", second.key_ptr.*);
    try std.testing.expect(it.next() == null);

    const encoded = try @import("encode.zig").encode(allocator, quotas, OrderedQuotaRoot, .{});
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(json_str, encoded);
}

test "decode - root mapOrdered with value mapper preserves input order" {
    const allocator = std.testing.allocator;

    const Event = struct {
        id: u32,
        score: i32,
    };

    const EventMapper = mapper.Mapper(Event, .{
        .id = .{ .alias = "eventId" },
    });
    const OrderedEventsRoot = Root.mapOrdered(EventMapper);
    const json_str = "{\"second\":{\"eventId\":2,\"score\":20},\"first\":{\"eventId\":1,\"score\":10}}";

    var by_name = try decode(allocator, OrderedEventsRoot, json_str, .{});
    defer by_name.deinit(allocator);

    var it = by_name.iterator();
    const first = it.next().?;
    const second = it.next().?;
    try std.testing.expectEqualStrings("second", first.key_ptr.*);
    try std.testing.expectEqualStrings("first", second.key_ptr.*);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(@as(u32, 2), by_name.get("second").?.id);

    const encoded = try @import("encode.zig").encode(allocator, by_name, OrderedEventsRoot, .{});
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(json_str, encoded);
}

test "decode - root mapOrdered duplicate use_last keeps first insertion position" {
    const allocator = std.testing.allocator;
    const OrderedQuotaRoot = Root.mapOrderedOf(i64);

    var quotas = try decode(allocator, OrderedQuotaRoot, "{\"a\":1,\"b\":2,\"a\":3}", .{
        .duplicate_field_behavior = .use_last,
    });
    defer quotas.deinit(allocator);

    // Value follows use_last, order follows first insertion.
    try std.testing.expectEqual(@as(i64, 3), quotas.get("a").?);

    var it = quotas.iterator();
    const first = it.next().?;
    const second = it.next().?;
    try std.testing.expectEqualStrings("a", first.key_ptr.*);
    try std.testing.expectEqualStrings("b", second.key_ptr.*);
    try std.testing.expect(it.next() == null);
}

test "decodeFromReader - root mapOrderedOf preserves input order" {
    const allocator = std.testing.allocator;
    const OrderedQuotaRoot = Root.mapOrderedOf(i64);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var reader: std.Io.Reader = .fixed("{\"second\":2,\"first\":1}");
    const quotas = try decodeFromReader(arena.allocator(), OrderedQuotaRoot, &reader, .{});

    var it = quotas.iterator();
    const first = it.next().?;
    const second = it.next().?;
    try std.testing.expectEqualStrings("second", first.key_ptr.*);
    try std.testing.expectEqualStrings("first", second.key_ptr.*);
    try std.testing.expect(it.next() == null);
}
