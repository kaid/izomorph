//! Izo 元数据类型系统
//!
//! 定义字段映射规则和元数据结构，用于 comptime 代码生成

const std = @import("std");

/// 嵌套配置 - 同时支持别名和嵌套 Mapper
pub const NestedConfig = struct {
    /// 字段别名
    alias: ?[]const u8 = null,
    /// 嵌套 Mapper 类型
    nested: ?type = null,
};

/// 字段映射规则
pub const FieldRule = union(enum) {
    /// 使用字段原名（默认行为）
    default,
    /// 使用别名进行序列化/反序列化
    alias: []const u8,
    /// 完全跳过该字段
    skip,
    /// 反序列化时缺失的默认值
    default_value: DefaultValue,
    /// 使用嵌套 Mapper（用于结构体字段）
    nested: type,
    /// 组合配置：别名 + 嵌套 Mapper
    combined: NestedConfig,

    /// 默认值包装器 - 需要在 comptime 存储任意类型的默认值
    pub const DefaultValue = struct {
        // 使用类型擦除存储默认值
        // 实际值通过 comptime 类型信息重建
        _type_id: usize = 0,
    };
};

/// 字段元数据 - comptime 生成
///
/// 包含字段在序列化/反序列化时所需的所有信息
pub const FieldMeta = struct {
    /// Zig 字段名
    name: []const u8,
    /// JSON/Protobuf 中的字段名（考虑 alias）
    serialized_name: []const u8,
    /// 是否应该跳过此字段
    should_skip: bool,
    /// 字段在结构体中的索引
    index: usize,
    /// 是否有嵌套 Mapper
    has_nested_mapper: bool,
    /// 嵌套 Mapper 类型（如果有）
    nested_mapper: type,
};

/// 类型映射元数据 - comptime 生成
///
/// 包含一个结构体类型的所有字段映射信息
pub const TypeMeta = struct {
    /// 字段元数据数组
    fields: []const FieldMeta,
    // 注意: Zig 不支持在 comptime 结构体中存储 type
    // _type: type,
};

/// 从结构体类型 comptime 生成字段元数据
///
/// 示例:
/// ```zig
/// const MyStruct = struct { name: []const u8, age: u32 };
/// const fields = comptime generateFieldMeta(MyStruct, .{
///     .name = .{ .alias = "person_name" },
/// });
/// ```
pub fn generateFieldMeta(comptime T: type, comptime config: anytype) []const FieldMeta {
    // 验证 T 是结构体类型
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("generateFieldMeta requires a struct type, got " ++ @typeName(T));
    }

    const struct_info = type_info.@"struct";

    // 使用递归 comptime 函数构建字段元数据数组
    // 这样可以避免 comptime var 的生命周期问题
    return comptime generateFieldsRecursive(struct_info.fields, config, 0, &[_]FieldMeta{});
}

/// 递归构建字段元数据数组
fn generateFieldsRecursive(
    comptime all_fields: anytype,
    comptime config: anytype,
    comptime index: usize,
    comptime accumulated: []const FieldMeta,
) []const FieldMeta {
    // 基本情况：所有字段处理完毕
    if (index >= all_fields.len) {
        return accumulated;
    }

    const field = all_fields[index];
    const rule = getFieldRule(config, field.name);

    // 确定序列化名称
    const serialized_name = comptime getSerializedName(field.name, rule);

    // 确定是否有嵌套 Mapper
    const has_nested = comptime switch (rule) {
        .nested => true,
        .combined => |combined| combined.nested != null,
        else => false,
    };

    // 确定嵌套 Mapper 类型
    const nested_type = comptime switch (rule) {
        .nested => |n| n,
        .combined => |combined| combined.nested orelse void,
        else => void,
    };

    const new_field_meta = FieldMeta{
        .name = field.name,
        .serialized_name = serialized_name,
        .should_skip = rule == .skip,
        .index = index,
        .has_nested_mapper = has_nested,
        .nested_mapper = nested_type,
    };

    // 递归处理下一个字段
    const new_accumulated = accumulated ++ [_]FieldMeta{new_field_meta};
    return generateFieldsRecursive(all_fields, config, index + 1, new_accumulated);
}

/// 从配置中获取指定字段的规则
fn getFieldRule(comptime config: anytype, comptime field_name: []const u8) FieldRule {
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);

    // 验证 config 是结构体类型
    if (config_info != .@"struct") {
        @compileError("Mapper config must be a struct literal");
    }

    // 遍历配置字段，查找匹配的字段名
    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            const raw_value = @field(config, field.name);
            const raw_type = @TypeOf(raw_value);

            // 检查是否直接是 FieldRule 类型（如 .skip, .default, .nested(...)）
            if (raw_type == FieldRule) {
                return raw_value;
            }

            // 检查是否是匿名结构体字面量
            const raw_type_info = @typeInfo(raw_type);
            if (raw_type_info == .@"struct") {
                const struct_fields = raw_type_info.@"struct".fields;

                // 收集所有配置项
                var has_alias: bool = false;
                var alias_value: ?[]const u8 = null;
                var has_nested: bool = false;
                var nested_value: ?type = null;
                var has_default_value: bool = false;

                inline for (struct_fields) |struct_field| {
                    if (comptime std.mem.eql(u8, struct_field.name, "alias")) {
                        has_alias = true;
                        alias_value = raw_value.alias;
                    } else if (comptime std.mem.eql(u8, struct_field.name, "nested")) {
                        has_nested = true;
                        nested_value = raw_value.nested;
                    } else if (comptime std.mem.eql(u8, struct_field.name, "default_value")) {
                        has_default_value = true;
                    }
                }

                // 如果有 alias 和 nested，返回组合规则
                if (has_alias and has_nested) {
                    return FieldRule{
                        .combined = .{
                            .alias = alias_value,
                            .nested = nested_value,
                        },
                    };
                }

                // 只有 alias
                if (has_alias) {
                    return FieldRule{ .alias = alias_value.? };
                }

                // 只有 nested
                if (has_nested) {
                    return FieldRule{ .nested = nested_value.? };
                }

                // 只有 default_value
                if (has_default_value) {
                    return FieldRule{ .default_value = .{} };
                }
            }

            // 检查是否是 enum 字面量（如 .skip, .default）
            if (raw_type_info == .enum_literal) {
                const literal_name = @tagName(raw_value);

                if (comptime std.mem.eql(u8, literal_name, "skip")) {
                    return .skip;
                } else if (comptime std.mem.eql(u8, literal_name, "default")) {
                    return .default;
                }
            }

            return .default;
        }
    }

    return .default;
}

/// 根据规则获取序列化名称
fn getSerializedName(comptime field_name: []const u8, comptime rule: FieldRule) []const u8 {
    return switch (rule) {
        .alias => |alias| alias,
        .combined => |combined| combined.alias orelse field_name,
        .default, .skip, .default_value, .nested => field_name,
    };
}

/// 检查类型是否需要递归处理（结构体或数组）
pub fn isComplexType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => true,
        .pointer => |ptr| ptr.size == .slice,
        else => false,
    };
}

// ==================== 测试 ====================

test "FieldRule - basic rules" {
    const rule1: FieldRule = .default;
    const rule2: FieldRule = .{ .alias = "new_name" };
    const rule3: FieldRule = .skip;

    try std.testing.expect(rule1 == .default);
    try std.testing.expect(rule2 == .alias);
    try std.testing.expect(std.mem.eql(u8, rule2.alias, "new_name"));
    try std.testing.expect(rule3 == .skip);
}

test "generateFieldMeta - basic struct" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const fields = comptime generateFieldMeta(Person, .{});

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(std.mem.eql(u8, fields[0].name, "name"));
    try std.testing.expect(std.mem.eql(u8, fields[0].serialized_name, "name"));
    try std.testing.expect(!fields[0].should_skip);
}

test "generateFieldMeta - with alias" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const fields = comptime generateFieldMeta(Person, .{
        .name = .{ .alias = "person_name" },
    });

    try std.testing.expect(std.mem.eql(u8, fields[0].serialized_name, "person_name"));
    try std.testing.expect(std.mem.eql(u8, fields[1].serialized_name, "age"));
}

test "generateFieldMeta - with skip" {
    const Person = struct {
        name: []const u8,
        secret: []const u8,
    };

    const fields = comptime generateFieldMeta(Person, .{
        .secret = .skip,
    });

    try std.testing.expect(!fields[0].should_skip);
    try std.testing.expect(fields[1].should_skip);
}

test "isComplexType" {
    const SimpleStruct = struct { x: i32 };

    try std.testing.expect(isComplexType(SimpleStruct));
    try std.testing.expect(isComplexType([]const u8));
    try std.testing.expect(isComplexType([10]u8));
    try std.testing.expect(!isComplexType(i32));
    // Note: 最后一个测试与第二个相同，跳过
}
