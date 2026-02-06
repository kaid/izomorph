//! Izo JSON Decoder - Implementation based on std.json
//!
//! Leverages Zig's mature standard library JSON implementation for reliable deserialization.
//! Field mapping is achieved through Mapper (alias resolution, field skipping, etc.).

const std = @import("std");
const meta_module = @import("../meta.zig");

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
    // Create Decoder type using Mapper
    const Decoder = createDecoder(T, MapperType);

    // Parse using std.json
    var scanner = std.json.Scanner.initCompleteInput(allocator, json_str);
    defer scanner.deinit();

    const options = std.json.ParseOptions{
        .ignore_unknown_fields = true, // We handle field mapping in jsonParse
        .duplicate_field_behavior = .use_last,
        .max_value_len = json_str.len, // Set max value to input string length
    };

    return try Decoder.jsonParse(allocator, &scanner, options);
}

/// Create decoder type
///
/// Creates a decoder type implementing jsonParse method for target type T,
/// applying Mapper's field mapping rules during parsing.
fn createDecoder(comptime T: type, comptime MapperType: type) type {
    return struct {
        /// Implements std.json parsing interface
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            // Verify input is object begin
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            // Create result struct
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** MapperType.fields.len;

            // Parse object fields
            while (true) {
                var name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse std.json.default_max_value_len);

                const json_field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break, // No more fields
                    else => return error.UnexpectedToken,
                };

                // Find matching serialized name in Mapper's fields
                var matched = false;
                inline for (MapperType.fields, 0..) |field_meta, i| {
                    if (field_meta.should_skip) continue;

                    if (std.mem.eql(u8, field_meta.serialized_name, json_field_name)) {
                        // Free name token
                        if (name_token) |token| {
                            switch (token) {
                                .allocated_string => |slice| allocator.free(slice),
                                else => {},
                            }
                        }
                        name_token = null;

                        // Handle duplicate fields
                        if (fields_seen[i]) {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    // Parse and ignore duplicate value
                                    _ = try parseFieldValue(allocator, source, field_meta, options);
                                    matched = true;
                                    break;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }

                        // Parse field value
                        @field(result, field_meta.name) = try parseFieldValue(allocator, source, field_meta, options);
                        fields_seen[i] = true;
                        matched = true;
                        break;
                    }
                }

                // If no matching field
                if (!matched) {
                    if (name_token) |token| {
                        switch (token) {
                            .allocated_string => |slice| allocator.free(slice),
                            else => {},
                        }
                    }

                    if (options.ignore_unknown_fields) {
                        try source.skipValue();
                    } else {
                        return error.UnknownField;
                    }
                }
            }

            // Fill default values (for unparsed fields)
            inline for (MapperType.fields, 0..) |field_meta, i| {
                if (field_meta.should_skip) continue;

                if (!fields_seen[i]) {
                    const field_type = @TypeOf(@field(result, field_meta.name));

                    if (comptime @typeInfo(field_type) == .optional) {
                        // Optional types default to null
                        @field(result, field_meta.name) = null;
                    }
                    // For non-optional types without provided values, keep uninitialized
                    // Better error handling may be needed in production applications
                }
            }

            return result;
        }

        /// Parse single field value
        fn parseFieldValue(
            allocator: std.mem.Allocator,
            source: anytype,
            comptime field_meta: meta_module.FieldMeta,
            options: std.json.ParseOptions,
        ) !@TypeOf(@field(@as(T, undefined), field_meta.name)) {
            const FieldType = @TypeOf(@field(@as(T, undefined), field_meta.name));

            // Ensure options allocate and max_value_len are set
            var actual_options = options;
            if (actual_options.allocate == null) {
                actual_options.allocate = .alloc_if_needed;
            }
            if (actual_options.max_value_len == null) {
                actual_options.max_value_len = std.json.default_max_value_len;
            }

            // If has nested Mapper, create nested decoder using it
            if (comptime field_meta.has_nested_mapper) {
                const NestedDecoder = createDecoder(FieldType, field_meta.nested_mapper);
                return try NestedDecoder.jsonParse(allocator, source, actual_options);
            }

            // If has element Mapper for arrays/slices
            if (comptime field_meta.has_element_mapper) {
                const ElementType = @typeInfo(FieldType).pointer.child;
                return try parseArrayWithElementMapper(ElementType, allocator, source, field_meta.element_mapper, actual_options);
            }

            // Otherwise use standard parsing
            return try std.json.innerParse(FieldType, allocator, source, actual_options);
        }

        /// Parse array with element mapper applied to each element
        fn parseArrayWithElementMapper(
            comptime ElementType: type,
            allocator: std.mem.Allocator,
            source: anytype,
            comptime ElementMapper: type,
            options: std.json.ParseOptions,
        ) ![]const ElementType {
            const ElementDecoder = createDecoder(ElementType, ElementMapper);

            // Parse array begin
            if (.array_begin != try source.next()) return error.UnexpectedToken;

            var list: std.ArrayList(ElementType) = .empty;
            errdefer list.deinit(allocator);

            // Parse elements until array end
            while (true) {
                if (try source.peekNextTokenType() == .array_end) {
                    _ = try source.next();
                    break;
                }

                const element = try ElementDecoder.jsonParse(allocator, source, options);
                try list.append(allocator, element);
            }

            return list.toOwnedSlice(allocator);
        }
    };
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

test "encode - array with element mapper" {
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

    const person = Person{
        .name = "Bob",
        .hobbies = &.{ .{ .name = "coding", .years = 10 }, .{ .name = "music", .years = 2 } },
    };

    const json = try @import("encode.zig").encode(allocator, person, PersonMapper, .{});
    defer allocator.free(json);

    // Verify output uses hobby_name alias for array elements
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hobby_name\":\"coding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hobby_name\":\"music\"") != null);
}
