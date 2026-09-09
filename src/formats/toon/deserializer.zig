const std = @import("std");
const compat = @import("compat");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;

pub fn toJsonSlice(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeJson(&aw.writer, value);
    return aw.toOwnedSlice();
}

pub fn writeJson(writer: *compat.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .uint => |u| try writer.print("{d}", .{u}),
        .float => |f| {
            if (std.math.isFinite(f)) {
                try writer.print("{d}", .{f});
            } else {
                try writer.writeAll("null");
            }
        },
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeJsonString(writer, s),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJson(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |entries| {
            try writer.writeByte('{');
            for (entries, 0..) |entry, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonString(writer, entry.key);
                try writer.writeByte(':');
                try writeJson(writer, entry.value);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeJsonString(writer: *compat.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0...7, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}
