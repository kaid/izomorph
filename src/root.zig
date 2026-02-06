//! Izomorph (Izo) - 结构保持型序列化库
//!
//! **Slogan:** Structure-preserving serialization for the Zig ecosystem.
//! Define once, encode anywhere.
//!
//! 核心理念:
//! - 在内存表示与传输表示之间建立结构保持的映射（同构）
//! - 利用 Zig 的 comptime 实现零开销抽象
//! - 一次定义映射规则，支持多种序列化格式
//!
//! 使用示例:
//! ```zig
//! const izo = @import("izomorph");
//!
//! const Person = struct {
//!     name: []const u8,
//!     age: u32,
//!     secret: []const u8,
//! };
//!
//! // 定义同构映射规则
//! const PersonMapper = izo.Mapper(Person, .{
//!     .name = .{ .alias = "person_name" },  // 字段别名
//!     .secret = .skip,                       // 跳过字段
//! });
//!
//! // 编码为 JSON
//! const json_str = try izo.json.encode(allocator, person, PersonMapper, .{});
//!
//! // 从 JSON 解码
//! const decoded = try izo.json.decode(allocator, Person, PersonMapper, json_str);
//! ```

const std = @import("std");

// ==================== 核心模块导出 ====================

/// 类型元数据系统
pub const meta = @import("meta.zig");

/// Mapper 核心结构
pub const Mapper = @import("mapper.zig").Mapper;

/// JSON 序列化模块
pub const json = struct {
    /// JSON 编码器
    pub const encode = @import("json/encode.zig").encode;
    /// 编码选项
    pub const EncodeOptions = @import("json/encode.zig").EncodeOptions;
    /// JSON 解码器
    pub const decode = @import("json/decode.zig").decode;
    /// 解码选项
    pub const DecodeOptions = @import("json/decode.zig").DecodeOptions;
};

// ==================== 向后兼容（模板代码） ====================

/// 用于演示 I/O 的辅助函数（将移除）
const Io = std.Io;

/// 接受 Io.Writer 实例，写入示例消息
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

/// 简单的加法函数（模板代码，将移除）
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

// ==================== 基础测试 ====================

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

// 完整 API 使用测试
test "izomorph - full API usage" {
    const allocator = std.testing.allocator;

    // 定义测试结构体
    const Person = struct {
        name: []const u8,
        age: u32,
        email: []const u8,
    };

    // 定义映射规则
    const PersonMapper = Mapper(Person, .{
        .name = .{ .alias = "person_name" },
        .email = .skip,
    });

    // 创建测试数据
    const person = Person{
        .name = "Alice",
        .age = 30,
        .email = "alice@example.com",
    };

    // 编码为 JSON
    const json_str = try json.encode(allocator, person, PersonMapper, .{});
    defer allocator.free(json_str);

    // 验证完整的 JSON 输出
    try std.testing.expectEqualStrings("{\"person_name\":\"Alice\",\"age\":30}", json_str);

    // 解码 JSON
    const decoded = try json.decode(allocator, Person, PersonMapper, json_str);
    try std.testing.expectEqualStrings("Alice", decoded.name);
    try std.testing.expectEqual(@as(u32, 30), decoded.age);
}
