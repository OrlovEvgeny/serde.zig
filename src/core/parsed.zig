const std = @import("std");

/// An owning parse result. May be moved, but must not be copied and deinitialized
/// twice. All allocations made by the parser and custom adapters live until deinit.
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
            self.* = undefined;
        }
    };
}

pub fn parse(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype, comptime Format: type) !Parsed(T) {
    // Managed maps and custom types can retain their allocator. Keep the arena
    // at a stable address even when the returned Parsed value is moved.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const value = try Format.fromSliceSchema(T, arena.allocator(), input, schema);
    return .{ .value = value, .arena = arena };
}
