const std = @import("std");
const serde = @import("serde");
const opts = serde;

const Status = enum(u8) {
    ok = 0,
    failed = 1,
    pending = 2,

    pub const serde = .{
        .enum_repr = opts.EnumRepr.integer,
    };
};

const Event = union(enum) {
    created: struct { by: []const u8 },
    updated: struct { by: []const u8, changes: u32 },
    deleted: void,

    pub const serde = .{
        .tag = opts.UnionTag.internal,
        .tag_field = "event_type",
    };
};

const Metadata = struct {
    request_id: []const u8,
    trace_id: []const u8 = "",
};

const ApiResponse = struct {
    user_id: u64,
    display_name: []const u8,
    email: ?[]const u8,
    score: f64 = 0.0,
    status: Status,
    tags: []const []const u8 = &.{},
    api_key: []const u8 = "",
    created_at: i64,
    metadata: Metadata,

    pub const serde = .{
        .rename = .{
            .user_id = "id",
        },
        .rename_all = opts.NamingConvention.camel_case,
        .skip = .{
            .api_key = opts.SkipMode.always,
            .email = opts.SkipMode.null,
            .tags = opts.SkipMode.empty,
        },
        .flatten = &[_][]const u8{"metadata"},
        .with = .{
            .created_at = opts.helpers.UnixTimestampMs,
        },
    };
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // --- Build an API response with all serde features ---
    const tags: []const []const u8 = &.{};
    const resp = ApiResponse{
        .user_id = 42,
        .display_name = "Alice",
        .email = null,
        .score = 98.5,
        .status = .ok,
        .tags = tags,
        .api_key = "super-secret-key-12345",
        .created_at = 1700000000,
        .metadata = .{
            .request_id = "req-abc123",
            .trace_id = "trace-def456",
        },
    };

    // --- Serialize to pretty JSON ---
    const json = try serde.json.toSliceWith(allocator, resp, .{ .pretty = true });
    defer allocator.free(json);
    std.debug.print("=== Serialized (pretty) ===\n{s}\n", .{json});

    // Key serde behaviors to observe in the output:
    //   "id"          — renamed from user_id
    //   "displayName" — rename_all camelCase
    //   no "apiKey"   — skip always
    //   no "email"    — skip null
    //   no "tags"     — skip empty
    //   "requestId"/"traceId" — flattened from metadata to top level
    //   "createdAt"   — 1700000000000 (ms, via UnixTimestampMs)
    //   "status"      — 0 (enum_repr = .integer)

    // --- Deserialize back ---
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try serde.json.fromSlice(ApiResponse, arena.allocator(), json);
    std.debug.print("\n=== Deserialized ===\n", .{});
    std.debug.print("user_id      = {}\n", .{parsed.user_id});
    std.debug.print("display_name = {s}\n", .{parsed.display_name});
    std.debug.print("email        = {?s}\n", .{parsed.email});
    std.debug.print("score        = {d}\n", .{parsed.score});
    std.debug.print("status       = .{s} (integer repr)\n", .{@tagName(parsed.status)});
    std.debug.print("tags.len     = {} (empty slice)\n", .{parsed.tags.len});
    std.debug.print("api_key      = \"{s}\" (default, was skip'd)\n", .{parsed.api_key});
    std.debug.print("created_at   = {} (seconds, deserialized from ms)\n", .{parsed.created_at});
    std.debug.print("request_id   = {s} (flattened from metadata)\n", .{parsed.metadata.request_id});
    std.debug.print("trace_id     = {s} (flattened from metadata)\n", .{parsed.metadata.trace_id});

    // --- Internal-tagged union example ---
    const created_event: Event = .{ .created = .{ .by = "admin" } };
    const event_json = try serde.json.toSlice(allocator, created_event);
    defer allocator.free(event_json);
    std.debug.print("\n=== Tagged union (internal) ===\n{s}\n", .{event_json});

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();

    const parsed_event = try serde.json.fromSlice(Event, arena2.allocator(), event_json);
    std.debug.print("Parsed event: created by \"{s}\"\n", .{parsed_event.created.by});
}
