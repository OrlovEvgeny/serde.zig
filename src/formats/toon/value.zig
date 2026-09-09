const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: Value,
    quoted: bool = false,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: []Value,
    object: []Entry,

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .number_string, .string => |s| allocator.free(s),
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .object => |entries| {
                for (entries) |entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        switch (self) {
            .null => return .null,
            .bool => |b| return .{ .bool = b },
            .int => |i| return .{ .int = i },
            .uint => |u| return .{ .uint = u },
            .float => |f| return .{ .float = f },
            .number_string => |s| return .{ .number_string = try dupe(allocator, s) },
            .string => |s| return .{ .string = try dupe(allocator, s) },
            .array => |items| {
                var out = try allocator.alloc(Value, items.len);
                @memset(out, .null);
                errdefer {
                    for (out[0..]) |item| item.deinit(allocator);
                    allocator.free(out);
                }
                for (items, 0..) |item, i| out[i] = try item.clone(allocator);
                return .{ .array = out };
            },
            .object => |entries| {
                var out = try allocator.alloc(Entry, entries.len);
                @memset(out, .{ .key = &.{}, .value = .null, .quoted = false });
                errdefer {
                    for (out[0..]) |entry| {
                        allocator.free(entry.key);
                        entry.value.deinit(allocator);
                    }
                    allocator.free(out);
                }
                for (entries, 0..) |entry, i| {
                    const key = try dupe(allocator, entry.key);
                    errdefer allocator.free(key);
                    const child = try entry.value.clone(allocator);
                    out[i] = .{
                        .key = key,
                        .value = child,
                        .quoted = entry.quoted,
                    };
                }
                return .{ .object = out };
            },
        }
    }
};

pub fn dupe(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len);
    @memcpy(out, bytes);
    return out;
}
