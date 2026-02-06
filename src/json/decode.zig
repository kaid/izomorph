//! Izo JSON 解码器 - 基于 std.json 的实现
//!
//! 利用 Zig 标准库的成熟 JSON 实现，提供可靠的反序列化功能。
//! 通过 Mapper 实现字段映射（别名解析、字段跳过等）。

const std = @import("std");
const meta_module = @import("../meta.zig");

/// JSON 解码错误集
pub const Error = std.json.ParseError(std.json.Scanner) || error{MissingField};

/// 解码选项
pub const DecodeOptions = struct {
    /// 遇到未知字段时的行为
    ignore_unknown_fields: bool = true,
    /// 遇到重复字段时的行为
    duplicate_field_behavior: enum {
        use_first,
        @"error",
        use_last,
    } = .use_last,
};

/// 将 JSON 字符串解码为指定类型
///
/// 使用示例:
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
    // 使用 Mapper 创建 Decoder 类型
    const Decoder = createDecoder(T, MapperType);

    // 使用 std.json 解析
    var scanner = std.json.Scanner.initCompleteInput(allocator, json_str);
    defer scanner.deinit();

    const options = std.json.ParseOptions{
        .ignore_unknown_fields = true, // 我们在 jsonParse 中处理字段映射
        .duplicate_field_behavior = .use_last,
        .max_value_len = json_str.len, // 设置最大值为输入字符串长度
    };

    return try Decoder.jsonParse(allocator, &scanner, options);
}

/// 创建解码器类型
///
/// 为目标类型 T 创建一个实现 jsonParse 方法的解码器类型，
/// 在解析过程中应用 Mapper 的字段映射规则。
fn createDecoder(comptime T: type, comptime MapperType: type) type {
    return struct {
        /// 实现 std.json 的解析接口
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!T {
            // 验证输入是对象开始
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            // 创建结果结构体
            var result: T = undefined;
            var fields_seen = [_]bool{false} ** MapperType.fields.len;

            // 解析对象字段
            while (true) {
                var name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse std.json.default_max_value_len);

                const json_field_name = switch (name_token.?) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break, // 没有更多字段了
                    else => return error.UnexpectedToken,
                };

                // 在 Mapper 的字段中查找匹配的序列化名称
                var matched = false;
                inline for (MapperType.fields, 0..) |field_meta, i| {
                    if (field_meta.should_skip) continue;

                    if (std.mem.eql(u8, field_meta.serialized_name, json_field_name)) {
                        // 释放名称 token
                        if (name_token) |token| {
                            switch (token) {
                                .allocated_string => |slice| allocator.free(slice),
                                else => {},
                            }
                        }
                        name_token = null;

                        // 处理重复字段
                        if (fields_seen[i]) {
                            switch (options.duplicate_field_behavior) {
                                .use_first => {
                                    // 解析并忽略重复值
                                    _ = try parseFieldValue(allocator, source, field_meta, options);
                                    matched = true;
                                    break;
                                },
                                .@"error" => return error.DuplicateField,
                                .use_last => {},
                            }
                        }

                        // 解析字段值
                        @field(result, field_meta.name) = try parseFieldValue(allocator, source, field_meta, options);
                        fields_seen[i] = true;
                        matched = true;
                        break;
                    }
                }

                // 如果没有匹配的字段
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

            // 填充默认值（对于未被解析的字段）
            inline for (MapperType.fields, 0..) |field_meta, i| {
                if (field_meta.should_skip) continue;

                if (!fields_seen[i]) {
                    const field_type = @TypeOf(@field(result, field_meta.name));

                    if (comptime @typeInfo(field_type) == .optional) {
                        // 可选类型默认为 null
                        @field(result, field_meta.name) = null;
                    }
                    // 对于非可选类型且未提供的情况，保持未初始化
                    // 在实际应用中可能需要更好的错误处理
                }
            }

            return result;
        }

        /// 解析单个字段的值
        fn parseFieldValue(
            allocator: std.mem.Allocator,
            source: anytype,
            comptime field_meta: meta_module.FieldMeta,
            options: std.json.ParseOptions,
        ) !@TypeOf(@field(@as(T, undefined), field_meta.name)) {
            const FieldType = @TypeOf(@field(@as(T, undefined), field_meta.name));

            // 确保 options 的 allocate 和 max_value_len 被设置
            var actual_options = options;
            if (actual_options.allocate == null) {
                actual_options.allocate = .alloc_if_needed;
            }
            if (actual_options.max_value_len == null) {
                actual_options.max_value_len = std.json.default_max_value_len;
            }

            // 如果有嵌套 Mapper，使用它创建嵌套解码器
            if (comptime field_meta.has_nested_mapper) {
                const NestedDecoder = createDecoder(FieldType, field_meta.nested_mapper);
                return try NestedDecoder.jsonParse(allocator, source, actual_options);
            }

            // 否则使用标准解析
            return try std.json.innerParse(FieldType, allocator, source, actual_options);
        }
    };
}

// ==================== 测试 ====================

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

    // JSON 使用别名
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

    // JSON 包含未知字段
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

    // 编码
    const person = Person{ .name = "Eve", .age = 28 };
    const encoded = try @import("encode.zig").encode(allocator, person, PersonMapper, .{});
    defer allocator.free(encoded);

    // 解码
    const decoded = try decode(allocator, Person, PersonMapper, encoded);

    try std.testing.expectEqualStrings(person.name, decoded.name);
    try std.testing.expectEqual(person.age, decoded.age);
}
