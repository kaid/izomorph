//! Izo Error Handling
//!
//! Provides detailed error messages and context for serialization operations

const std = @import("std");

/// Main error set for serialization operations
pub const SerializeError = error{
    InvalidJson,
    UnexpectedToken,
    UnknownField,
    DuplicateField,
    MissingField,
    TypeMismatch,
    OutOfMemory,
    InvalidFieldValue,
};

/// Error context containing detailed information
pub const ErrorContext = struct {
    /// Error type
    err: SerializeError,
    /// Field name (if applicable)
    field_name: ?[]const u8,
    /// JSON path to the error location
    json_path: []const u8,
    /// Original error message
    message: []const u8,
    /// Line number (if available)
    line: ?usize,
    /// Column number (if available)
    column: ?usize,
    /// Suggested fix (if available)
    suggestion: ?[]const u8,

    /// Format error message
    pub fn format(self: ErrorContext, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        try list.writer(allocator).print("SerializeError: {s}\n", .{@errorName(self.err)});

        if (self.field_name) |name| {
            try list.writer(allocator).print("  Field: {s}\n", .{name});
        }

        try list.writer(allocator).print("  Path: {s}\n", .{self.json_path});
        try list.writer(allocator).print("  Message: {s}\n", .{self.message});

        if (self.line) |line| {
            try list.writer(allocator).print("  Location: line {d}", .{line});
            if (self.column) |col| {
                try list.writer(allocator).print(", column {d}", .{col});
            }
            try list.writer(allocator).writeByte('\n');
        }

        if (self.suggestion) |suggestion| {
            try list.writer(allocator).print("  Suggestion: {s}\n", .{suggestion});
        }

        return list.toOwnedSlice(allocator);
    }
};

/// Error handler for JSON parsing
pub const ErrorHandler = struct {
    /// Current JSON path stack
    path_stack: std.ArrayList([]const u8),
    /// Last error context
    last_error: ?ErrorContext,

    pub fn init(allocator: std.mem.Allocator) ErrorHandler {
        return .{
            .path_stack = std.ArrayList([]const u8).init(allocator),
            .last_error = null,
        };
    }

    pub fn deinit(self: *ErrorHandler) void {
        self.path_stack.deinit();
        if (self.last_error) |*err| {
            // Free error context resources if needed
            _ = err;
        }
    }

    /// Push field name to path stack
    pub fn pushField(self: *ErrorHandler, name: []const u8) !void {
        try self.path_stack.append(name);
    }

    /// Pop field from path stack
    pub fn popField(self: *ErrorHandler) void {
        _ = self.path_stack.pop();
    }

    /// Get current JSON path
    pub fn getCurrentPath(self: *ErrorHandler, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        try list.append(allocator, '$');
        for (self.path_stack.items) |field| {
            try list.writer(allocator).print(".{s}", .{field});
        }
        return list.toOwnedSlice(allocator);
    }

    /// Create error context
    pub fn createError(
        self: *ErrorHandler,
        allocator: std.mem.Allocator,
        err: SerializeError,
        field_name: ?[]const u8,
        message: []const u8,
        suggestion: ?[]const u8,
    ) !ErrorContext {
        const path = try self.getCurrentPath(allocator);
        errdefer allocator.free(path);

        return .{
            .err = err,
            .field_name = field_name,
            .json_path = path,
            .message = message,
            .line = null,
            .column = null,
            .suggestion = suggestion,
        };
    }
};

// ==================== Tests ====================

test "ErrorContext - format" {
    const allocator = std.testing.allocator;

    const ctx: ErrorContext = .{
        .err = SerializeError.UnknownField,
        .field_name = "unknown_field",
        .json_path = "$.person.unknown_field",
        .message = "Field not found in struct",
        .line = 10,
        .column = 25,
        .suggestion = "Check field name or add to ignore list",
    };

    const formatted = try ctx.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "UnknownField") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "unknown_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "line 10") != null);
}

test "ErrorHandler - path tracking" {
    const allocator = std.testing.allocator;
    var handler = ErrorHandler.init(allocator);
    defer handler.deinit();

    try handler.pushField("person");
    try handler.pushField("address");
    try handler.pushField("street");

    const path = try handler.getCurrentPath(allocator);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("$.person.address.street", path);
}
