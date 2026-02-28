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

/// Encode a value to JSON and write directly to a writer (zero-allocation streaming)
///
/// This function allows encoding directly to any writer without intermediate memory allocation.
/// Useful for streaming JSON output to network sockets, files, or other sinks.
///
/// Usage example:
/// ```zig
/// var buffer: [256]u8 = undefined;
/// var writer: std.Io.Writer = .fixed(&buffer);
/// try izo.json.encodeToWriter(&writer, person, PersonMapper, .{});
/// const json_str = writer.buffered();
/// ```
///
/// For LLM Gateway scenarios, you can write directly to a socket:
/// ```zig
/// var socket_writer: std.Io.Writer = ...;
/// try izo.json.encodeToWriter(&socket_writer, response, ResponseMapper, .{});
/// ```
pub fn encodeToWriter(
    writer: *std.Io.Writer,
    value: anytype,
    comptime MapperType: type,
    options: EncodeOptions,
) std.json.Stringify.Error!void {
    const Adapter = @import("adapter.zig").createAdapter(MapperType);
    const adapter = Adapter{ .value = value };
    try std.json.Stringify.value(adapter, options.toStdOptions(), writer);
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

test "encode - union variant with omit_null mapper" {
    const allocator = std.testing.allocator;

    // Define a variant struct with optional field
    const TextContent = struct {
        pub const Mapper = mapper.Mapper(@This(), .{
            .optional_field = .{ .omit_null = true },
        });

        value: []const u8,
        optional_field: ?[]const u8,
    };

    // Define a discriminated union
    const Content = union(enum) {
        text: TextContent,
        number: i64,
    };

    const ContentMapper = mapper.Mapper(Content, .{
        .union_strategy = .{ .discriminated = "type" },
    });

    // Test with null optional_field - should be omitted
    const content_with_null = Content{
        .text = .{
            .value = "hello",
            .optional_field = null,
        },
    };

    const result1 = try encode(allocator, content_with_null, ContentMapper, .{});
    defer allocator.free(result1);

    // Verify optional_field is omitted when null
    try std.testing.expectEqualStrings("{\"type\":\"text\",\"value\":\"hello\"}", result1);

    // Test with non-null optional_field - should be included
    const content_with_value = Content{
        .text = .{
            .value = "world",
            .optional_field = "extra",
        },
    };

    const result2 = try encode(allocator, content_with_value, ContentMapper, .{});
    defer allocator.free(result2);

    // Verify optional_field is included when not null
    try std.testing.expectEqualStrings("{\"type\":\"text\",\"value\":\"world\",\"optional_field\":\"extra\"}", result2);
}

test "encode - bare union variant with mapper" {
    const allocator = std.testing.allocator;

    // Define a variant struct with optional field and mapper
    const TextData = struct {
        pub const Mapper = mapper.Mapper(@This(), .{
            .content = .{ .alias = "text" },
            .metadata = .{ .omit_null = true },
        });

        content: []const u8,
        metadata: ?[]const u8,
    };

    // Define a bare union
    const Data = union(enum) {
        text: TextData,
        raw: []const u8,
    };

    const DataMapper = mapper.Mapper(Data, .{
        .union_strategy = .bare,
    });

    // Test struct variant with mapper - should apply alias and omit_null
    const data_with_null = Data{
        .text = .{
            .content = "hello",
            .metadata = null,
        },
    };

    const result1 = try encode(allocator, data_with_null, DataMapper, .{});
    defer allocator.free(result1);

    // Verify alias is applied and null field is omitted
    try std.testing.expectEqualStrings("{\"text\":\"hello\"}", result1);

    // Test with non-null metadata
    const data_with_metadata = Data{
        .text = .{
            .content = "world",
            .metadata = "extra info",
        },
    };

    const result2 = try encode(allocator, data_with_metadata, DataMapper, .{});
    defer allocator.free(result2);

    // Verify all fields included when metadata is not null
    try std.testing.expectEqualStrings("{\"text\":\"world\",\"metadata\":\"extra info\"}", result2);

    // Test scalar variant - should work as before
    const data_raw = Data{ .raw = "direct string" };

    const result3 = try encode(allocator, data_raw, DataMapper, .{});
    defer allocator.free(result3);

    // Verify bare scalar serialization
    try std.testing.expectEqualStrings("\"direct string\"", result3);
}

// ==================== encodeToWriter Tests ====================

test "encodeToWriter - basic struct" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const person = Person{
        .name = "Alice",
        .age = 30,
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encodeToWriter(&writer, person, PersonMapper, .{});

    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", writer.buffered());
}

test "encodeToWriter - struct with alias" {
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

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encodeToWriter(&writer, person, PersonMapper, .{});

    try std.testing.expectEqualStrings("{\"person_name\":\"Bob\",\"age\":25}", writer.buffered());
}

test "encodeToWriter - struct with skip" {
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

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encodeToWriter(&writer, person, PersonMapper, .{});

    try std.testing.expectEqualStrings("{\"name\":\"Charlie\"}", writer.buffered());
}

test "encodeToWriter - nested struct with mapping" {
    const Address = struct {
        street: []const u8,
        city: []const u8,
        zip: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

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

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encodeToWriter(&writer, person, PersonMapper, .{});

    try std.testing.expectEqualStrings(
        "{\"full_name\":\"Alice\",\"address\":{\"road\":\"123 Main St\",\"city\":\"New York\"}}",
        writer.buffered(),
    );
}

test "encodeToWriter - with pretty printing" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{});

    const person = Person{
        .name = "Alice",
        .age = 30,
    };

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try encodeToWriter(&writer, person, PersonMapper, .{ .pretty = true });

    const expected =
        \\{
        \\  "name": "Alice",
        \\  "age": 30
        \\}
    ;
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "encodeToWriter - zero allocation comparison" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = mapper.Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const person = Person{
        .name = "Dave",
        .age = 40,
    };

    // Method 1: encode() with allocation
    const allocated_result = try encode(allocator, person, PersonMapper, .{});
    defer allocator.free(allocated_result);

    // Method 2: encodeToWriter() to fixed buffer
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try encodeToWriter(&writer, person, PersonMapper, .{});

    // Both should produce identical output
    try std.testing.expectEqualStrings(allocated_result, writer.buffered());
}

// ============================================================================
// mzp Integration Tests - Verify fixes for izomorph issues
// ============================================================================

const json = std.json;

// ============================================================================
// Test Types - Defined at module level for comptime resolution
// ============================================================================

// Test 1: RequestId with bare union strategy
const TestRequestId = union(enum) {
    string: []const u8,
    number: i64,
    pub const Mapper = mapper.Mapper(TestRequestId, .{ .union_strategy = .bare });
};

const TestMessageWithId = struct {
    id: TestRequestId,
    method: []const u8,
    pub const Mapper = mapper.Mapper(TestMessageWithId, .{});
};

// Test 2: ErrorCode with bare enum strategy
const TestErrorCode = enum(i32) {
    method_not_found = -32601,
    pub const Mapper = mapper.Mapper(TestErrorCode, .{ .enum_strategy = .bare });
};

const TestErrorResponse = struct {
    code: TestErrorCode,
    message: []const u8,
    pub const Mapper = mapper.Mapper(TestErrorResponse, .{});
};

// Test 3: Capability with alias
const TestCapability = struct {
    list_changed: bool = false,
    pub const Mapper = mapper.Mapper(TestCapability, .{
        .list_changed = .{ .alias = "listChanged" },
    });
};

const TestServerCapabilities = struct {
    tools: ?TestCapability = null,
    pub const Mapper = mapper.Mapper(TestServerCapabilities, .{
        .tools = .{ .omit_null = true },
    });
};

// Test 4: TaskStatus with custom enum strategy
const TestTaskStatus = enum {
    queued,
    running,
    completed,
    pub const Mapper = mapper.Mapper(TestTaskStatus, .{
        .enum_strategy = .custom,
        .custom = struct {
            pub fn serialize(value: TestTaskStatus) []const u8 {
                return switch (value) {
                    .queued, .running => "working",
                    .completed => "completed",
                };
            }
        }.serialize,
    });
};

const TestTask = struct {
    status: TestTaskStatus,
    pub const Mapper = mapper.Mapper(TestTask, .{});
};

// ============================================================================
// Test Functions
// ============================================================================

test "mzp integration - RequestId with bare union strategy" {
    const allocator = std.testing.allocator;

    const msg = TestMessageWithId{
        .id = .{ .number = 42 },
        .method = "test",
    };

    const json_str = try encode(allocator, msg, TestMessageWithId.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"id":42,"method":"test"}, NOT {"id":{"number":42},"method":"test"}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"number\":42") == null);
}

test "mzp integration - ErrorCode with bare enum strategy" {
    const allocator = std.testing.allocator;

    const err = TestErrorResponse{
        .code = .method_not_found,
        .message = "Not found",
    };

    const json_str = try encode(allocator, err, TestErrorResponse.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"code":-32601,"message":"Not found"}, NOT {"code":"method_not_found",...}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"method_not_found\"") == null);
}

test "mzp integration - Capability with alias" {
    const allocator = std.testing.allocator;

    const caps = TestServerCapabilities{
        .tools = .{ .list_changed = true },
    };

    const json_str = try encode(allocator, caps, TestServerCapabilities.Mapper, .{});
    defer allocator.free(json_str);

    // Should contain "listChanged" (alias), NOT "list_changed" (original)
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"listChanged\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"list_changed\"") == null);
}

test "mzp integration - TaskStatus with custom enum strategy" {
    const allocator = std.testing.allocator;

    const task = TestTask{ .status = .running };

    const json_str = try encode(allocator, task, TestTask.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"status":"working"}, NOT {"status":"running"}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"status\":\"working\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"running\"") == null);
}

// Test for double serialization issue
test "nested mapper should not cause double serialization" {
    const allocator = std.testing.allocator;

    const DoubleInner = struct {
        value: i32,
        pub const Mapper = mapper.Mapper(@This(), .{});
    };

    const DoubleOuter = struct {
        inner: DoubleInner,
        pub const Mapper = mapper.Mapper(@This(), .{
            .inner = .{ .nested = DoubleInner.Mapper },
        });
    };

    const outer = DoubleOuter{ .inner = .{ .value = 42 } };
    const json_str = try encode(allocator, outer, DoubleOuter.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"inner":{"value":42}}, not {"innerinner":...} or similar
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"inner\":{\"value\":42}") != null);
}

// Test for custom field serializer - array to map conversion
test "custom serializer - array to map" {
    const allocator = std.testing.allocator;

    const Item = struct {
        id: []const u8,
        value: i32,
    };

    const Container = struct {
        items: []const Item,
        pub const Mapper = mapper.Mapper(@This(), .{
            .items = .{
                .custom = struct {
                    pub fn serialize(items: []const Item, jws: anytype) !void {
                        try jws.beginObject();
                        for (items) |item| {
                            try jws.objectField(item.id);
                            try jws.write(item.value);
                        }
                        try jws.endObject();
                    }
                }.serialize,
            },
        });
    };

    const container = Container{
        .items = &.{
            .{ .id = "a", .value = 1 },
            .{ .id = "b", .value = 2 },
        },
    };

    const json_str = try encode(allocator, container, Container.Mapper, .{});
    defer allocator.free(json_str);

    // Should convert array to map: {"items":{"a":1,"b":2}}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"items\":{\"a\":1,\"b\":2}") != null);
}

// Test for custom field serializer - simple formatting
test "custom serializer - simple formatting" {
    const allocator = std.testing.allocator;

    const Data = struct {
        value: i32,
        pub const Mapper = mapper.Mapper(@This(), .{
            .value = .{
                .custom = struct {
                    pub fn serialize(val: i32, jws: anytype) !void {
                        // Custom format: wrap in quotes with prefix
                        var buf: [64]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "value_{d}", .{val}) catch unreachable;
                        try jws.write(str);
                    }
                }.serialize,
            },
        });
    };

    const data = Data{ .value = 42 };
    const json_str = try encode(allocator, data, Data.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"value":"value_42"}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"value\":\"value_42\"") != null);
}

// Test for custom deserializer - simple value conversion
test "custom deserializer - simple value conversion" {
    const allocator = std.testing.allocator;

    const Data = struct {
        raw_value: i32,
        pub const Mapper = mapper.Mapper(@This(), .{
            .raw_value = .{
                .custom = struct {
                    pub fn serialize(val: i32, jws: anytype) !void {
                        // Serialize as string with prefix
                        var buf: [64]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "val_{d}", .{val}) catch unreachable;
                        try jws.write(str);
                    }
                }.serialize,
                .custom_deserialize = struct {
                    pub fn deserialize(allocator2: std.mem.Allocator, source: anytype) !i32 {
                        _ = allocator2;
                        const token = try source.next();
                        const str = switch (token) {
                            .string => |s| s,
                            .allocated_string => |s| s,
                            else => return error.UnexpectedToken,
                        };
                        // Parse "val_XXX" format
                        if (str.len < 5 or !std.mem.eql(u8, str[0..4], "val_")) {
                            return error.SyntaxError;
                        }
                        return try std.fmt.parseInt(i32, str[4..], 10);
                    }
                },
            },
        });
    };

    // Serialize
    const data = Data{ .raw_value = 42 };
    const json_str = try encode(allocator, data, Data.Mapper, .{});
    defer allocator.free(json_str);

    // Should be {"raw_value":"val_42"}
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"raw_value\":\"val_42\"") != null);

    // Deserialize
    const decoded = try @import("decode.zig").decode(allocator, Data.Mapper, json_str);
    try std.testing.expectEqual(@as(i32, 42), decoded.raw_value);
}
