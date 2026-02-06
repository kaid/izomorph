//! Izo Mapper - 基于 std.json 的类型映射系统
//!
//! Mapper 为结构体类型生成配置，并通过 Adapter 模式与 std.json 集成。

const std = @import("std");
const meta_module = @import("meta.zig");

/// Mapper 配置类型
///
/// 使用示例:
/// ```zig
/// const Person = struct {
///     name: []const u8,
///     age: u32,
///     secret: []const u8,
/// };
///
/// const PersonMapper = izo.Mapper(Person, .{
///     .name = .{ .alias = "person_name" },
///     .secret = .skip,
/// });
/// ```
pub fn Mapper(comptime T: type, comptime config: anytype) type {
    // 验证配置类型
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);
    if (config_info != .@"struct") {
        @compileError("Mapper config must be a struct literal, got " ++ @typeName(ConfigType));
    }

    // 验证 T 是结构体
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Mapper requires a struct type, got " ++ @typeName(T));
    }

    // 在 comptime 生成字段元数据
    const fields_meta = comptime meta_module.generateFieldMeta(T, config);

    return struct {
        /// 映射的目标类型
        pub const TargetType = T;

        /// 预计算的字段元数据数组
        pub const fields: []const meta_module.FieldMeta = fields_meta;

        /// 创建适配器，用于与 std.json 集成
        ///
        /// 适配器包装原始值并实现 jsonStringify 方法
        pub fn adapter(value: T) Adapter {
            return Adapter{ .value = value };
        }

        /// 适配器类型 - 实现 std.json 的 jsonStringify 接口
        pub const Adapter = struct {
            value: T,

            /// 实现 std.json 的序列化接口
            ///
            /// 此方法会被 std.json.stringify 自动调用
            pub fn jsonStringify(self: @This(), jws: anytype) !void {
                try jws.beginObject();

                // 遍历所有字段
                inline for (fields) |field_meta| {
                    if (field_meta.should_skip) continue;

                    // 使用映射后的字段名
                    try jws.objectField(field_meta.serialized_name);

                    // 获取字段值
                    const field_value = @field(self.value, field_meta.name);

                    // 如果有嵌套 Mapper，使用它的 Adapter 包装字段值
                    if (comptime field_meta.has_nested_mapper) {
                        const NestedAdapter = comptime getNestedAdapter(field_meta.nested_mapper);
                        const nested_adapter = NestedAdapter{ .value = field_value };
                        try jws.write(nested_adapter);
                    } else {
                        // 否则直接序列化字段值
                        try jws.write(field_value);
                    }
                }

                try jws.endObject();
            }
        };

        /// 获取嵌套 Mapper 的 Adapter 类型
        fn getNestedAdapter(comptime NestedMapper: type) type {
            // 验证这是一个有效的 Mapper 类型
            if (!@hasDecl(NestedMapper, "Adapter")) {
                @compileError("Nested mapper must have an Adapter type");
            }
            return NestedMapper.Adapter;
        }

        /// 获取字段的序列化名称
        pub fn getSerializedName(comptime field_name: []const u8) []const u8 {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.serialized_name;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// 检查字段是否应该被跳过
        pub fn shouldSkipField(comptime field_name: []const u8) bool {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.should_skip;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// 获取所有非跳过的字段数量（comptime 计算）
        pub fn getActiveFieldCount() usize {
            return comptime blk: {
                var count: usize = 0;
                for (fields) |field| {
                    if (!field.should_skip) count += 1;
                }
                break :blk count;
            };
        }

        /// 通过序列化名称查找字段元数据
        /// 用于反序列化时的字段匹配
        pub fn findFieldBySerializedName(serialized_name: []const u8) ?meta_module.FieldMeta {
            inline for (fields) |field| {
                if (field.should_skip) continue;
                if (std.mem.eql(u8, field.serialized_name, serialized_name)) {
                    return field;
                }
            }
            return null;
        }
    };
}

// ==================== 测试 ====================

test "Mapper - basic usage" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{});

    try std.testing.expectEqual(Person, PersonMapper.TargetType);
    try std.testing.expectEqual(@as(usize, 2), PersonMapper.getActiveFieldCount());
}

test "Mapper - with alias" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    try std.testing.expect(std.mem.eql(u8, PersonMapper.getSerializedName("name"), "person_name"));
    try std.testing.expect(std.mem.eql(u8, PersonMapper.getSerializedName("age"), "age"));
}

test "Mapper - with skip" {
    const Person = struct {
        name: []const u8,
        secret: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .secret = .skip,
    });

    try std.testing.expectEqual(@as(usize, 2), PersonMapper.getActiveFieldCount());
    try std.testing.expect(!PersonMapper.shouldSkipField("name"));
    try std.testing.expect(PersonMapper.shouldSkipField("secret"));
    try std.testing.expect(!PersonMapper.shouldSkipField("age"));
}

test "Mapper - findFieldBySerializedName" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const field_opt = PersonMapper.findFieldBySerializedName("person_name");
    try std.testing.expect(field_opt != null);
    try std.testing.expect(std.mem.eql(u8, field_opt.?.name, "name"));

    const not_found = PersonMapper.findFieldBySerializedName("nonexistent");
    try std.testing.expect(not_found == null);
}

test "Mapper - adapter jsonStringify" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
    });

    const person = Person{
        .name = "Alice",
        .age = 30,
    };

    const adapter = PersonMapper.adapter(person);

    // 使用 std.json.Stringify.valueAlloc 测试适配器
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, adapter, .{});
    defer allocator.free(json);

    // 验证 JSON 包含别名
    try std.testing.expect(std.mem.indexOf(u8, json, "\"person_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Alice\"") != null);
}

// ==================== 嵌套 Mapper 测试 ====================

test "Mapper - nested struct with mapping" {
    const Address = struct {
        street: []const u8,
        city: []const u8,
        password: []const u8,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    // 为嵌套结构体定义 Mapper
    const AddressMapper = Mapper(Address, .{
        .password = .skip,
        .street = .{ .alias = "road" },
    });

    // 为主结构体定义 Mapper，引用嵌套 Mapper
    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
        .address = .{ .nested = AddressMapper },
    });

    const person = Person{
        .name = "Alice",
        .address = .{
            .street = "123 Main St",
            .city = "New York",
            .password = "secret123",
        },
    };

    const adapter = PersonMapper.adapter(person);
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, adapter, .{});
    defer allocator.free(json);

    // 验证外层别名
    try std.testing.expect(std.mem.indexOf(u8, json, "\"person_name\"") != null);
    // 验证嵌套结构体的字段映射
    try std.testing.expect(std.mem.indexOf(u8, json, "\"road\"") != null); // street -> road
    try std.testing.expect(std.mem.indexOf(u8, json, "\"street\"") == null);
    // 验证嵌套结构体的跳过
    try std.testing.expect(std.mem.indexOf(u8, json, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret123") == null);
    // 验证未修改的字段
    try std.testing.expect(std.mem.indexOf(u8, json, "\"city\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"New York\"") != null);
}

test "Mapper - deeply nested with multiple mappers" {
    const Hobby = struct {
        name: []const u8,
        years: u32,
        secret_note: []const u8,
    };

    const Address = struct {
        street: []const u8,
        hobbies: []const Hobby,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    // 为每个嵌套层级定义 Mapper
    // 注意：HobbyMapper 定义了但尚未应用于数组元素
    // 数组元素映射将在后续版本支持
    _ = Mapper(Hobby, .{
        .secret_note = .skip,
        .years = .{ .alias = "experience_years" },
    });

    const AddressMapper = Mapper(Address, .{
        .street = .{ .alias = "road" },
    });

    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "full_name" },
        .address = .{ .nested = AddressMapper },
    });

    const person = Person{
        .name = "Bob",
        .address = .{
            .street = "456 Oak Ave",
            .hobbies = &.{
                .{ .name = "reading", .years = 5, .secret_note = "my favorite" },
            },
        },
    };

    const adapter = PersonMapper.adapter(person);
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, adapter, .{});
    defer allocator.free(json);

    // 验证外层映射
    try std.testing.expect(std.mem.indexOf(u8, json, "\"full_name\"") != null);
    // 验证第一层嵌套映射
    try std.testing.expect(std.mem.indexOf(u8, json, "\"road\"") != null);
    // 注意：hobbies 数组内的结构体还没有应用 HobbyMapper
    // 这需要更复杂的数组元素映射，将在后续版本支持
}
