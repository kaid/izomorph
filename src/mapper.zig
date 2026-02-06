//! Izo Mapper - Type mapping system based on std.json
//!
//! Mapper generates configuration for struct types and integrates with std.json via Adapter pattern.

const std = @import("std");
const meta_module = @import("meta.zig");

/// Mapper configuration type
///
/// Usage example:
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
    // Validate config type
    const ConfigType = @TypeOf(config);
    const config_info = @typeInfo(ConfigType);
    if (config_info != .@"struct") {
        @compileError("Mapper config must be a struct literal, got " ++ @typeName(ConfigType));
    }

    // Verify T is a struct
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Mapper requires a struct type, got " ++ @typeName(T));
    }

    // Generate field metadata at comptime
    const fields_meta = comptime meta_module.generateFieldMeta(T, config);

    return struct {
        /// Target type for mapping
        pub const TargetType = T;

        /// Precomputed field metadata array
        pub const fields: []const meta_module.FieldMeta = fields_meta;

        /// Create adapter for std.json integration
        ///
        /// Adapter wraps the original value and implements jsonStringify method
        pub fn adapter(value: T) Adapter {
            return Adapter{ .value = value };
        }

        /// Adapter type - implements std.json jsonStringify interface
        pub const Adapter = struct {
            value: T,

            /// Implements std.json serialization interface
            ///
            /// This method is automatically called by std.json.stringify
            pub fn jsonStringify(self: @This(), jws: anytype) !void {
                try jws.beginObject();

                // Iterate over all fields
                inline for (fields) |field_meta| {
                    if (field_meta.should_skip) continue;

                    // Use mapped field name
                    try jws.objectField(field_meta.serialized_name);

                    // Get field value
                    const field_value = @field(self.value, field_meta.name);

                    // If has nested Mapper, use its Adapter to wrap field value
                    if (comptime field_meta.has_nested_mapper) {
                        const NestedAdapter = comptime getNestedAdapter(field_meta.nested_mapper);
                        const nested_adapter = NestedAdapter{ .value = field_value };
                        try jws.write(nested_adapter);
                    } else {
                        // Otherwise serialize field value directly
                        try jws.write(field_value);
                    }
                }

                try jws.endObject();
            }
        };

        /// Get Adapter type for nested Mapper
        fn getNestedAdapter(comptime NestedMapper: type) type {
            // Verify it's a valid Mapper type
            if (!@hasDecl(NestedMapper, "Adapter")) {
                @compileError("Nested mapper must have an Adapter type");
            }
            return NestedMapper.Adapter;
        }

        /// Get serialized name for a field
        pub fn getSerializedName(comptime field_name: []const u8) []const u8 {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.serialized_name;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// Check if field should be skipped
        pub fn shouldSkipField(comptime field_name: []const u8) bool {
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, field_name)) {
                    return field.should_skip;
                }
            }
            @compileError("Field '" ++ field_name ++ "' not found in " ++ @typeName(T));
        }

        /// Get count of non-skipped fields (computed at comptime)
        pub fn getActiveFieldCount() usize {
            return comptime blk: {
                var count: usize = 0;
                for (fields) |field| {
                    if (!field.should_skip) count += 1;
                }
                break :blk count;
            };
        }

        /// Find field metadata by serialized name
        /// Used for field matching during deserialization
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

// ==================== Tests ====================

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

    // Test adapter using std.json.Stringify.valueAlloc
    const allocator = std.testing.allocator;
    const json = try std.json.Stringify.valueAlloc(allocator, adapter, .{});
    defer allocator.free(json);

    // Verify JSON contains alias
    try std.testing.expect(std.mem.indexOf(u8, json, "\"person_name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Alice\"") != null);
}

// ==================== Nested Mapper Tests ====================

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

    // Define Mapper for nested struct
    const AddressMapper = Mapper(Address, .{
        .password = .skip,
        .street = .{ .alias = "road" },
    });

    // Define Mapper for main struct, referencing nested Mapper
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

    // Verify outer alias
    try std.testing.expect(std.mem.indexOf(u8, json, "\"person_name\"") != null);
    // Verify nested struct field mapping
    try std.testing.expect(std.mem.indexOf(u8, json, "\"road\"") != null); // street -> road
    try std.testing.expect(std.mem.indexOf(u8, json, "\"street\"") == null);
    // Verify nested struct skip
    try std.testing.expect(std.mem.indexOf(u8, json, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret123") == null);
    // Verify unchanged fields
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

    // Define Mappers for each nesting level
    // Note: HobbyMapper is defined but not yet applied to array elements
    // Array element mapping will be supported in future versions
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

    // Verify outer mapping
    try std.testing.expect(std.mem.indexOf(u8, json, "\"full_name\"") != null);
    // Verify first level nested mapping
    try std.testing.expect(std.mem.indexOf(u8, json, "\"road\"") != null);
    // Note: Hobbies array inner structs don't have HobbyMapper applied yet
    // This requires more complex array element mapping, will be supported in future versions
}
