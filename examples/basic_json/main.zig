const std = @import("std");
const serde = @import("serde");

const Point = struct { x: i32, y: i32 };

const User = struct {
    id: u64,
    name: []const u8,
    active: bool,
};

const Response = struct {
    status: []const u8,
    code: i32,
    data: []const i32,
    message: ?[]const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // --- Serialize a simple struct ---
    const point = Point{ .x = 10, .y = 20 };
    const json = try serde.json.toSlice(allocator, point);
    defer allocator.free(json);
    std.debug.print("Point -> JSON:  {s}\n", .{json});

    // --- Pretty-printed ---
    const pretty = try serde.json.toSliceWith(allocator, point, .{ .pretty = true });
    defer allocator.free(pretty);
    std.debug.print("Point -> pretty:\n{s}\n", .{pretty});

    // --- Deserialize back ---
    const parsed_point = try serde.json.fromSlice(Point, allocator, json);
    std.debug.print("JSON -> Point:  {{ .x = {}, .y = {} }}\n\n", .{ parsed_point.x, parsed_point.y });

    // --- Nested struct with strings (ArenaAllocator for easy cleanup) ---
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json_str = "{\"id\":42,\"name\":\"Alice\",\"active\":true}";
    const user = try serde.json.fromSlice(User, arena.allocator(), json_str);
    std.debug.print("User from JSON: {{ .id = {}, .name = \"{s}\", .active = {} }}\n", .{ user.id, user.name, user.active });

    const user_json = try serde.json.toSlice(allocator, user);
    defer allocator.free(user_json);
    std.debug.print("User -> JSON:   {s}\n\n", .{user_json});

    // --- Struct with slice and optional ---
    const data: []const i32 = &.{ 100, 200, 300 };
    const resp = Response{
        .status = "ok",
        .code = 200,
        .data = data,
        .message = null,
    };
    const resp_json = try serde.json.toSlice(allocator, resp);
    defer allocator.free(resp_json);
    std.debug.print("Response -> JSON (null message): {s}\n", .{resp_json});

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();

    const parsed_resp = try serde.json.fromSlice(Response, arena2.allocator(), resp_json);
    std.debug.print("Response <- JSON: status=\"{s}\", code={}, data_len={}, message={s}\n", .{
        parsed_resp.status,
        parsed_resp.code,
        parsed_resp.data.len,
        if (parsed_resp.message) |m| m else "(null)",
    });
}
