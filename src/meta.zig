//! Izo Metadata Type System
//!
//! Defines field mapping rules and metadata structures for comptime code generation

const std = @import("std");

/// Union serialization strategy - Tagged Union for mutually exclusive options
///
/// Usage:
///   .strategy = .bare           - Output value directly (default)
///   .strategy = .{ .discriminated = "type" }  - Output with type field
pub const UnionStrategy = union(enum) {
    /// Bare/Scalar mode - output the value directly without wrapping
    bare,
    /// Discriminated union mode - output with a type field
    discriminated: []const u8,
};

/// Custom serializer function type
pub const CustomSerializerFn = *const fn (value: anytype, jws: anytype) anyerror!void;

/// Custom deserializer - stored as a type containing the deserialize function
/// Example: struct { pub fn deserialize(allocator: Allocator, source: anytype) !T { ... } }
pub const CustomDeserializer = type;

/// Field serialization strategy - Tagged Union for mutually exclusive options
///
/// Usage:
///   .strategy = .skip                   - Skip this field entirely
///   .strategy = .default                - Use default serialization
///   .strategy = .{ .nested = Mapper }   - Use nested mapper
///   .strategy = .{ .custom = .{ .to = ..., .from = ... } }  - Custom serialization
pub const FieldStrategy = union(enum) {
    /// Skip this field during serialization/deserialization
    skip,
    /// Default serialization - use Zig's default or type's Mapper
    default,
    /// Use nested Mapper for this field
    nested: type,
    /// Custom serialization with optional deserialize
    custom: CustomConfig,
};

/// Custom serializer/deserializer configuration.
///
/// Usage example:
/// ```zig
/// const MySerializer = struct {
///     // Two signatures supported:
///     // 1. fn serialize(value: T, jws: anytype) !void
///     // 2. fn serialize(value: T, jws: anytype, helpers: anytype) !void
///     pub fn serialize(value: MyType, jws: anytype, helpers: anytype) !void {
///         // helpers methods available when using 3-param signature:
///         // - helpers.writeMapped(value: anytype) !void
///         // See: src/json/adapter.zig - fn Helpers() for full implementation
///         try helpers.writeMapped(nested_value);
///     }
/// };
///
/// const MyDeserializer = struct {
///     pub fn deserialize(allocator: std.mem.Allocator, source: anytype) !MyType {
///         // ...
///     }
/// };
///
/// const config = .{
///     .strategy = .{ .custom = .{
///         .to = MySerializer,
///         .from = MyDeserializer,
///         .with = &.{NestedType.Mapper},  // Mappers for helpers.writeMapped()
///     }},
/// };
/// ```
pub const CustomConfig = struct {
    /// Serializer type - should have pub fn serialize(...)
    /// Signature: fn (value: T, jws: anytype) !void
    ///     OR: fn (value: T, jws: anytype, helpers: anytype) !void
    /// For helpers methods, see src/json/adapter.zig fn Helpers()
    to: type = void,
    /// Deserializer type - should have:
    /// fn deserialize(allocator: std.mem.Allocator, source: anytype) !T
    from: type = void,
    /// Optional array of mapper types for auto-matching in custom serializers.
    /// Used by helpers.writeMapped() to find matching mappers.
    /// Example: .with = &.{JsonSchemaMapper, OtherMapper}
    with: ?[]const type = null,

    pub fn hasSerializer(comptime self: CustomConfig) bool {
        return self.to != void;
    }

    pub fn hasDeserializer(comptime self: CustomConfig) bool {
        return self.from != void;
    }

    /// Check if any mappers are configured
    pub fn hasMappers(comptime self: CustomConfig) bool {
        return self.with != null and self.with.?.len > 0;
    }
};

/// Nested configuration - supports both alias and nested Mapper simultaneously
pub const NestedConfig = struct {
    /// Field alias
    alias: ?[]const u8 = null,
    /// Element Mapper type for array/slice fields
    element_mapper: ?type = null,
    /// Whether to omit null optional fields during serialization
    omit_null: bool = false,
    /// Whether to omit fields that equal their default value during serialization
    omit_default: bool = false,
    /// Field serialization strategy
    strategy: FieldStrategy = .default,
};

/// Union for storing comptime-known default values
pub const DefaultValueUnion = union(enum) {
    none,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    string: []const u8,
};

/// Field metadata - generated at comptime
///
/// Contains all information needed for serialization/deserialization
pub const FieldMeta = struct {
    /// Zig field name
    name: []const u8,
    /// JSON/Protobuf field name (considering alias)
    serialized_name: []const u8,
    /// Whether this field should be skipped
    should_skip: bool,
    /// Field index in the struct
    index: usize,
    /// Whether has default value
    has_default_value: bool,
    /// Default value (if exists)
    default_value: DefaultValueUnion,
    /// Whether an element Mapper exists for arrays/slices
    has_element_mapper: bool,
    /// Element Mapper type for arrays/slices (if exists)
    element_mapper: type,
    /// Whether to omit null optional fields during serialization
    omit_null: bool,
    /// Whether to omit fields that equal their default value during serialization
    omit_default: bool,
    /// Field serialization strategy
    strategy: FieldStrategy,
};

/// Type mapping metadata - generated at comptime
///
/// Contains all field mapping information for a struct type
pub const TypeMeta = struct {
    /// Field metadata array
    fields: []const FieldMeta,
    // Note: Zig doesn't support storing type in comptime structs
    // _type: type,
};

/// Generate field metadata from struct type at comptime
///
/// Example:
/// ```zig
/// const MyStruct = struct { name: []const u8, age: u32 };
/// const fields = comptime generateFieldMeta(MyStruct, .{
///     .name = .{ .alias = "person_name" },
/// });
/// ```
pub fn generateFieldMeta(comptime T: type, comptime config: anytype) []const FieldMeta {
    // Verify T is a struct type
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("generateFieldMeta requires a struct type, got " ++ @typeName(T));
    }

    const struct_info = type_info.@"struct";

    // Use recursive comptime function to build field metadata array
    // This avoids comptime var lifetime issues
    return comptime generateFieldsRecursive(struct_info.fields, config, 0, &[_]FieldMeta{});
}

/// Recursively build field metadata array
fn generateFieldsRecursive(
    comptime all_fields: anytype,
    comptime config: anytype,
    comptime index: usize,
    comptime accumulated: []const FieldMeta,
) []const FieldMeta {
    // Base case: all fields processed
    if (index >= all_fields.len) {
        return accumulated;
    }

    const field = all_fields[index];
    const field_config = comptime getFieldConfig(config, field.name);

    // Determine serialized name
    const serialized_name = comptime field_config.alias orelse field.name;

    // Determine element mapper
    const has_element = field_config.element_mapper != null;
    const element_type = field_config.element_mapper orelse void;

    const new_field_meta = FieldMeta{
        .name = field.name,
        .serialized_name = serialized_name,
        .should_skip = false, // TODO: handle skip
        .index = index,
        .has_default_value = false,
        .default_value = .none,
        .has_element_mapper = has_element,
        .element_mapper = element_type,
        .omit_null = field_config.omit_null,
        .omit_default = field_config.omit_default,
        .strategy = field_config.strategy,
    };

    // Recursively process next field
    const new_accumulated = accumulated ++ [_]FieldMeta{new_field_meta};
    return generateFieldsRecursive(all_fields, config, index + 1, new_accumulated);
}

/// Get field configuration from mapper config
fn getFieldConfig(comptime config: anytype, comptime field_name: []const u8) NestedConfig {
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);

    // Default config
    var result: NestedConfig = .{};

    // Verify config is a struct type
    if (config_info != .@"struct") {
        return result;
    }

    // Iterate over config fields to find matching field name
    inline for (config_info.@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            const raw_value = @field(config, field.name);
            const raw_type = @TypeOf(raw_value);
            const raw_type_info = @typeInfo(raw_type);

            // Check if it's an enum literal like .skip
            if (raw_type_info == .enum_literal) {
                const literal_name = @tagName(raw_value);
                if (comptime std.mem.eql(u8, literal_name, "skip")) {
                    result.strategy = .skip;
                }
            } else if (raw_type_info == .@"struct") {
                // Extract all configuration fields
                inline for (raw_type_info.@"struct".fields) |struct_field| {
                    if (comptime std.mem.eql(u8, struct_field.name, "alias")) {
                        result.alias = @field(raw_value, "alias");
                    } else if (comptime std.mem.eql(u8, struct_field.name, "element_mapper")) {
                        result.element_mapper = @field(raw_value, "element_mapper");
                    } else if (comptime std.mem.eql(u8, struct_field.name, "omit_null")) {
                        result.omit_null = @field(raw_value, "omit_null");
                    } else if (comptime std.mem.eql(u8, struct_field.name, "omit_default")) {
                        result.omit_default = @field(raw_value, "omit_default");
                    } else if (comptime std.mem.eql(u8, struct_field.name, "strategy")) {
                        const strategy_value = @field(raw_value, "strategy");
                        const strategy_type = @TypeOf(strategy_value);
                        const strategy_info = @typeInfo(strategy_type);

                        // Check if strategy is an anonymous struct literal like .{ .nested = ... }
                        if (strategy_info == .@"struct") {
                            inline for (strategy_info.@"struct".fields) |strat_field| {
                                if (comptime std.mem.eql(u8, strat_field.name, "nested")) {
                                    result.strategy = .{ .nested = strategy_value.nested };
                                } else if (comptime std.mem.eql(u8, strat_field.name, "custom")) {
                                    // For custom strategy, we need to extract the custom config
                                    const custom_value = strategy_value.custom;
                                    var SerializerType: type = void;
                                    var DeserializerType: type = void;
                                    var MappersSlice: ?[]const type = null;

                                    const custom_type_info = @typeInfo(@TypeOf(custom_value));
                                    if (custom_type_info == .@"struct") {
                                        inline for (custom_type_info.@"struct".fields) |custom_field| {
                                            if (comptime std.mem.eql(u8, custom_field.name, "to")) {
                                                SerializerType = @field(custom_value, "to");
                                            } else if (comptime std.mem.eql(u8, custom_field.name, "from")) {
                                                DeserializerType = @field(custom_value, "from");
                                            } else if (comptime std.mem.eql(u8, custom_field.name, "with")) {
                                                MappersSlice = @field(custom_value, "with");
                                            }
                                        }
                                    }

                                    result.strategy = .{ .custom = .{ .to = SerializerType, .from = DeserializerType, .with = MappersSlice } };
                                }
                            }
                        } else if (strategy_type == FieldStrategy) {
                            result.strategy = strategy_value;
                        }
                    }
                }
            }

            break;
        }
    }

    return result;
}

/// Check if type needs recursive processing (struct or array)
pub fn isComplexType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => true,
        .pointer => |ptr| ptr.size == .slice,
        else => false,
    };
}

// ==================== Tests ====================

test "generateFieldMeta - basic struct" {
    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const fields = comptime generateFieldMeta(Person, .{});

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(std.mem.eql(u8, fields[0].name, "name"));
    try std.testing.expect(std.mem.eql(u8, fields[0].serialized_name, "name"));
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

test "isComplexType" {
    const SimpleStruct = struct { x: i32 };

    try std.testing.expect(isComplexType(SimpleStruct));
    try std.testing.expect(isComplexType([]const u8));
    try std.testing.expect(isComplexType([10]u8));
    try std.testing.expect(!isComplexType(i32));
    // Note: Last test is same as second, skipped
}
