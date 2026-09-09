const std = @import("std");
const serde = @import("serde");
const testing = std.testing;
const alloc = testing.allocator;
const de = serde.core;

const Required = struct { text: []const u8 = "default", required: i32 };
const Renamed = struct {
    text: []const u8,
    pub const serde = .{ .alias = .{ .text = &.{"alias"} } };
};
const Leaf = struct {
    text: []const u8,
    optional: ?i32,
    count: i32 = 7,
    pub const serde = .{ .rename = .{ .text = "name" } };
};
const Flat = struct {
    leaf: Leaf,
    pub const serde = .{ .flatten = &.{"leaf"} };
};
const DeepFlat = struct {
    flat: Flat,
    pub const serde = .{ .flatten = &.{"flat"} };
};
const Internal = union(enum) {
    item: Flat,
    none,
    pub const serde = .{ .tag = .internal, .tag_field = "kind" };
};
const Adjacent = union(enum) {
    item: Leaf,
    none,
    pub const serde = .{ .tag = .adjacent, .tag_field = "kind", .content_field = "data" };
};

test "defaults, duplicates and trailing data clean up owned memory" {
    try testing.expectError(error.MissingField, serde.json.fromSlice(Required, alloc, "{}"));
    try testing.expectError(error.MissingField, serde.json.fromSlice(Required, alloc, "{\"text\":\"owned\"}"));
    try testing.expectError(error.DuplicateField, serde.json.fromSlice(Renamed, alloc, "{\"text\":\"a\",\"alias\":\"b\"}"));
    try testing.expectError(error.TrailingData, serde.json.fromSlice(Required, alloc, "{\"required\":1}x"));
    try testing.expectError(error.TrailingData, serde.json.fromSlice(Renamed, alloc, "{\"text\":\"owned\"}x"));
    try testing.expectError(error.MissingField, serde.json.fromSlice(DeepFlat, alloc, "{}"));
}

test "partial and overlong containers release every element" {
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice([1][]const u8, alloc, "[\"a\",\"b\"]"));
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice(struct { []const u8 }, alloc, "[\"a\",\"b\"]"));
    try testing.expectError(error.WrongType, serde.json.fromSlice([]const []const u8, alloc, "[\"a\",true]"));
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice(union(enum) { item: []const u8 }, alloc, "{\"item\":\"a\",\"extra\":1}"));
}

test "borrowed array strings retain input addresses and survive errors" {
    const input = "[\"one\",\"two\"]";
    const value = try serde.json.fromSliceBorrowed([2][]const u8, alloc, input);
    try testing.expectEqual(@intFromPtr(input.ptr) + 2, @intFromPtr(value[0].ptr));
    try testing.expectEqual(@intFromPtr(input.ptr) + 8, @intFromPtr(value[1].ptr));
    try testing.expectError(error.WrongType, serde.json.fromSliceBorrowed([]const []const u8, alloc, "[\"one\",false]"));
    try testing.expectError(error.TrailingData, serde.json.fromSliceBorrowed([2][]const u8, alloc, input ++ "x"));
    try testing.expectError(error.InvalidEscape, serde.json.fromSliceBorrowed([1][]const u8, alloc, "[\"a\\nb\"]"));
}

test "flatten and union payloads obey nested settings in both directions" {
    const inputs = [_][]const u8{
        "{\"kind\":\"item\",\"name\":\"value\"}",
        "{\"name\":\"value\",\"kind\":\"item\"}",
    };
    for (inputs) |input| {
        const value = try serde.json.fromSlice(Internal, alloc, input);
        defer de.freeAllocated(Internal, value, alloc);
        try testing.expectEqualStrings("value", value.item.leaf.text);
        try testing.expectEqual(@as(i32, 7), value.item.leaf.count);
        const bytes = try serde.msgpack.toSlice(alloc, value);
        defer alloc.free(bytes);
        const decoded = try serde.msgpack.fromSlice(Internal, alloc, bytes);
        defer de.freeAllocated(Internal, decoded, alloc);
        try testing.expectEqualStrings("value", decoded.item.leaf.text);
    }
    for ([_][]const u8{
        "{\"kind\":\"item\",\"data\":{\"name\":\"v\"}}",
        "{\"data\":{\"name\":\"v\"},\"kind\":\"item\"}",
    }) |input| {
        const value = try serde.json.fromSlice(Adjacent, alloc, input);
        defer de.freeAllocated(Adjacent, value, alloc);
        try testing.expectEqualStrings("v", value.item.text);
    }
}

fn allocationPaths(allocator: std.mem.Allocator) !void {
    const value = try serde.json.fromSlice(DeepFlat, allocator, "{\"na\\u006de\":\"v\"}");
    defer de.freeAllocated(DeepFlat, value, allocator);
    const array = try serde.json.fromSlice([]const []const u8, allocator, "[\"one\",\"two\"]");
    defer de.freeAllocated(@TypeOf(array), array, allocator);
    const map = try serde.json.fromSlice(std.StringHashMap([]const u8), allocator, "{\"key\":\"old\",\"key\":\"new\"}");
    defer de.freeAllocated(@TypeOf(map), map, allocator);
    try testing.expectEqualStrings("new", map.get("key").?);
    const tagged = try serde.json.fromSlice(Adjacent, allocator, "{\"data\":{\"name\":\"v\"},\"kind\":\"item\"}");
    defer de.freeAllocated(Adjacent, tagged, allocator);
}
test "core paths release all allocations at every allocation failure" {
    try testing.checkAllAllocationFailures(alloc, allocationPaths, .{});
}

fn treePaths(allocator: std.mem.Allocator) !void {
    const T = struct { name: []const u8, values: []const []const u8 };
    const toml = try serde.toml.fromSlice(T, allocator, "name = \"ok\"\nvalues = [\"a\", \"b\"]\n");
    defer de.freeAllocated(T, toml, allocator);
    const yaml = try serde.yaml.fromSlice(T, allocator, "name: ok\nvalues: [a, b]\n");
    defer de.freeAllocated(T, yaml, allocator);
}
test "TOML and YAML temporary trees and result allocation failures" {
    try testing.checkAllAllocationFailures(alloc, treePaths, .{});
}

test "skipped JSON strings and enum names validate unicode escapes" {
    for ([_][]const u8{ "\\uZZZZ", "\\uDC00", "\\uD800x", "\\uD800\\u0041" }) |bad| {
        const input = try std.fmt.allocPrint(alloc, "{{\"ignored\":\"{s}\"}}", .{bad});
        defer alloc.free(input);
        try testing.expectError(error.InvalidUnicode, serde.json.fromSlice(struct {}, alloc, input));
    }
    const Color = enum { red, green };
    try testing.expectEqual(Color.green, try serde.json.fromSlice(Color, alloc, "\"gr\\u0065en\""));
    try testing.expectError(error.InvalidUnicode, serde.json.fromSlice(Color, alloc, "\"\\uZZZZ\""));
}

fn managedPaths(allocator: std.mem.Allocator) !void {
    // Allocating Io.Writer exposes allocation failures as WriteFailed.
    return managedPathsInner(allocator) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}
fn managedPathsInner(allocator: std.mem.Allocator) !void {
    const T = struct { name: []const u8, count: i32 = 7 };
    inline for (.{ serde.json, serde.msgpack, serde.toml, serde.yaml, serde.xml, serde.zon, serde.toon, serde.etf }) |format| {
        const input = try format.toSlice(allocator, T{ .name = "owned" });
        defer allocator.free(input);
        var parsed = try format.fromSliceManaged(T, allocator, input);
        defer parsed.deinit();
        try testing.expectEqualStrings("owned", parsed.value.name);
        var schema_parsed = try format.fromSliceManagedSchema(T, allocator, input, .{ .skip_deserializing = .{ .count = true }, .default = .{ .count = 11 } });
        defer schema_parsed.deinit();
        try testing.expectEqual(@as(i32, 11), schema_parsed.value.count);
    }
    const csv_input = "name,count\nowned,7\n";
    var csv = try serde.csv.fromSliceManaged([]const T, allocator, csv_input);
    defer csv.deinit();
    try testing.expectEqualStrings("owned", csv.value[0].name);
    var csv_schema = try serde.csv.fromSliceManagedSchema([]const T, allocator, "label,count\nowned,7\n", .{ .rename = .{ .name = "label" } });
    defer csv_schema.deinit();
    try testing.expectEqualStrings("owned", csv_schema.value[0].name);
    var map = try serde.json.fromSliceManaged(std.StringHashMap(i32), allocator, "{\"a\":1}");
    defer map.deinit();
    // A retained allocator must refer to the heap arena, even after return.
    try map.value.put("b", 2);
    try testing.expectEqual(@as(i32, 2), map.value.get("b").?);
}
test "managed results own all formats and retain a stable allocator" {
    try testing.checkAllAllocationFailures(alloc, managedPaths, .{});
}

test "directional skip and external false overrides" {
    const T = struct {
        secret: i32 = 1,
        local: i32 = 2,
        pub const serde = .{ .skip_serializing = .{ .secret = true }, .skip_deserializing = .{ .local = true } };
    };
    const bytes = try serde.json.toSlice(alloc, T{});
    defer alloc.free(bytes);
    try testing.expectEqualStrings("{\"local\":2}", bytes);
    const parsed = try serde.json.fromSlice(T, alloc, "{\"secret\":3,\"local\":4}");
    try testing.expectEqual(@as(i32, 3), parsed.secret);
    try testing.expectEqual(@as(i32, 2), parsed.local);
    const override = try serde.json.fromSliceSchema(T, alloc, "{\"local\":4}", .{ .skip_deserializing = .{ .local = false } });
    try testing.expectEqual(@as(i32, 4), override.local);
}

fn valuePaths(allocator: std.mem.Allocator) !void {
    const v = try serde.Value.fromAny(DeepFlat, .{ .flat = .{ .leaf = .{ .text = "v", .optional = null } } }, allocator);
    defer v.deinit(allocator);
    try testing.expectEqualStrings("name", v.object[0].key);
    const result = try v.toType(DeepFlat, allocator);
    defer de.freeAllocated(DeepFlat, result, allocator);
    try testing.expectEqualStrings("v", result.flat.leaf.text);
    const tagged = try serde.Value.fromAny(Adjacent, .{ .item = .{ .text = "value", .optional = null } }, allocator);
    defer tagged.deinit(allocator);
    const parsed = try tagged.toType(Adjacent, allocator);
    defer de.freeAllocated(Adjacent, parsed, allocator);
}
test "Value conversions share type settings and allocation cleanup" {
    try testing.checkAllAllocationFailures(alloc, valuePaths, .{});
}

const AdaptedInt = struct { n: i32 };
const IntAdapter = struct {
    pub fn serialize(value: AdaptedInt, s: anytype) @TypeOf(s.*).Error!void {
        try s.serializeInt(value.n);
    }
    pub fn deserialize(comptime _: type, _: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!AdaptedInt {
        return .{ .n = try d.deserializeInt(i32) };
    }
};
const AdapterContainer = struct {
    field: AdaptedInt,
    optional: ?AdaptedInt,
    array: [1]AdaptedInt,
    slice: []const AdaptedInt,
    tuple: struct { AdaptedInt, i32 },
    map: std.StringHashMap(AdaptedInt),
    tagged: union(enum) { value: AdaptedInt },
};
const NestedWireHelper = struct {
    pub const WireType = struct { value: AdaptedInt };
    pub fn serialize(value: AdaptedInt) WireType {
        return .{ .value = value };
    }
    pub fn deserialize(value: WireType) AdaptedInt {
        return value.value;
    }
};
fn adapterPaths(allocator: std.mem.Allocator) !void {
    const adapters = .{.{ AdaptedInt, IntAdapter }};
    const WithContainer = struct {
        item: AdaptedInt,
        pub const serde = .{ .with = .{ .item = NestedWireHelper } };
    };
    const with_value = WithContainer{ .item = .{ .n = 7 } };
    const with_bytes = serde.json.toSliceWithMap(allocator, with_value, adapters) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer allocator.free(with_bytes);
    try testing.expectEqualStrings("{\"item\":{\"value\":7}}", with_bytes);
    const with_parsed = try serde.json.fromSliceWithMap(WithContainer, allocator, with_bytes, adapters);
    try testing.expectEqual(@as(i32, 7), with_parsed.item.n);
    const input = "{\"field\":1,\"optional\":2,\"array\":[3],\"slice\":[4],\"tuple\":[5,6],\"map\":{\"k\":7},\"tagged\":{\"value\":8}}";
    const value = try serde.json.fromSliceWithMap(AdapterContainer, allocator, input, adapters);
    defer de.freeAllocated(AdapterContainer, value, allocator);
    try testing.expectEqual(@as(i32, 4), value.slice[0].n);
    const bytes = serde.json.toSliceWithMap(allocator, value, adapters) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer allocator.free(bytes);
    try testing.expectEqualStrings(input, bytes);
    var writer: serde.compat.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var serializer = serde.msgpack.Serializer.init(&writer.writer, allocator);
    serde.serializeWith(AdapterContainer, value, &serializer, adapters) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    var d = serde.msgpack.Deserializer.init(writer.written());
    const roundtrip = try serde.deserializeWith(AdapterContainer, allocator, &d, adapters);
    defer de.freeAllocated(AdapterContainer, roundtrip, allocator);
    try testing.expectEqual(@as(i32, 8), roundtrip.tagged.value.n);
}
test "external adapters propagate through all container shapes" {
    try testing.checkAllAllocationFailures(alloc, adapterPaths, .{});
}

fn failurePaths(allocator: std.mem.Allocator) !void {
    const Untagged = union(enum) {
        first: Renamed,
        second: []const u8,
        pub const serde = .{ .tag = .untagged };
    };
    const value = try serde.json.fromSlice(Untagged, allocator, "{\"text\":\"allocated\"}");
    defer de.freeAllocated(Untagged, value, allocator);
    try testing.expectEqualStrings("allocated", value.first.text);
    const csv = try serde.csv.fromSlice([]const Renamed, allocator, "text\nfirst\nsecond\n");
    defer de.freeAllocated(@TypeOf(csv), csv, allocator);
    const tagged = try serde.json.fromSlice(Internal, allocator, "{\"name\":\"v\",\"kind\":\"item\"}");
    defer de.freeAllocated(Internal, tagged, allocator);
}
test "untagged OOM and CSV failures propagate without leaks" {
    try testing.checkAllAllocationFailures(alloc, failurePaths, .{});
}

test "schema defaults and borrowed maps are safe on failure" {
    const T = struct { value: []const u8, required: i32 };
    const schema = .{ .default = .{ .value = "default" } };
    try testing.expectError(error.MissingField, serde.json.fromSliceSchema(T, alloc, "{}", schema));
    try testing.expectError(error.TrailingData, serde.json.fromSliceSchema(T, alloc, "{\"required\":1}x", schema));
    try testing.expectError(error.WrongType, serde.json.fromSliceBorrowed(std.StringHashMap([]const u8), alloc, "{\"a\":\"view\",\"b\":false}"));
}

test "writer failures release deferred serializer containers" {
    const T = struct { nested: struct { name: []const u8 }, rows: []const struct { v: i32 } };
    const value = T{ .nested = .{ .name = "long text" }, .rows = &.{.{ .v = 3 }} };
    for (0..24) |n| {
        var buffer: [24]u8 = undefined;
        var writer: serde.compat.Io.Writer = .fixed(buffer[0..n]);
        try testing.expectError(error.WriteFailed, serde.toml.toWriter(alloc, &writer, value));
        writer = .fixed(buffer[0..n]);
        try testing.expectError(error.WriteFailed, serde.msgpack.toWriter(alloc, &writer, value));
    }
}

fn layoutAdapterPaths(allocator: std.mem.Allocator) !void {
    return layoutAdapterPathsInner(allocator) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}
fn layoutAdapterPathsInner(allocator: std.mem.Allocator) !void {
    const T = struct { scalar: AdaptedInt, nested: struct { value: AdaptedInt }, list: []const AdaptedInt, optional: ?AdaptedInt };
    const value = T{ .scalar = .{ .n = 1 }, .nested = .{ .value = .{ .n = 2 } }, .list = &.{.{ .n = 3 }}, .optional = .{ .n = 4 } };
    const map = .{.{ AdaptedInt, IntAdapter }};
    inline for (.{ serde.toml, serde.yaml, serde.xml }) |format| {
        var writer: serde.compat.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        var s = if (format == serde.toml) format.Serializer.init(&writer.writer, allocator) else if (format == serde.xml) format.Serializer.init(&writer.writer, .{}) else format.Serializer.init(&writer.writer);
        if (format == serde.xml) try writer.writer.writeAll("<root>");
        try serde.serializeWith(T, value, &s, map);
        if (format == serde.xml) try writer.writer.writeAll("</root>");
        if (format == serde.toml) {
            const tree = try format.parse(allocator, writer.written());
            defer (format.Value{ .table = tree }).deinit(allocator);
            var d = format.Deserializer.init(&tree);
            const parsed = try serde.deserializeWith(T, allocator, &d, map);
            defer de.freeAllocated(T, parsed, allocator);
            try testing.expectEqual(@as(i32, 3), parsed.list[0].n);
        } else if (format == serde.yaml) {
            const tree = try format.parse(allocator, writer.written());
            defer tree.deinit(allocator);
            var d = format.Deserializer.init(&tree);
            const parsed = try serde.deserializeWith(T, allocator, &d, map);
            defer de.freeAllocated(T, parsed, allocator);
            try testing.expectEqual(@as(i32, 4), parsed.optional.?.n);
        } else {
            var d = format.Deserializer.init(writer.written());
            _ = try d.scanner.next(); // The low-level XML interface starts inside the root.
            const parsed = try serde.deserializeWith(T, allocator, &d, map);
            defer de.freeAllocated(T, parsed, allocator);
            try testing.expectEqual(@as(i32, 2), parsed.nested.value.n);
        }
    }
}
test "layout-sensitive formats preserve nested adapter container shapes" {
    try testing.checkAllAllocationFailures(alloc, layoutAdapterPaths, .{});
}

fn yamlOwnedTrees(allocator: std.mem.Allocator) !void {
    const input = "base: &b {name: original}\nbase: replaced\nitems:\n  - <<: *b\n    label: text\n  - name: next\n";
    const value = try serde.yaml.parse(allocator, input);
    defer value.deinit(allocator);
    const documents = try serde.yaml.parseAllValues(allocator, "---\nvalue: &a hello\ncopy: *a\n---\nvalue: world\n");
    defer {
        for (documents) |doc| doc.deinit(allocator);
        allocator.free(documents);
    }
}
test "YAML compact mappings and replaced anchors own their trees" {
    try testing.checkAllAllocationFailures(alloc, yamlOwnedTrees, .{});
}
test "CSV and XML serialize recursive flattened field settings" {
    const value = DeepFlat{ .flat = .{ .leaf = .{ .text = "hello", .optional = 2 } } };
    const csv = try serde.csv.toSlice(alloc, @as([]const DeepFlat, &.{value}));
    defer alloc.free(csv);
    try testing.expect(std.mem.startsWith(u8, csv, "name,optional,count"));
    const xml = try serde.xml.toSlice(alloc, value);
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<name>hello</name>") != null);
}

fn xmlEntityPaths(allocator: std.mem.Allocator) !void {
    const T = struct { text: []const u8 };
    const value = try serde.xml.fromSlice(T, allocator, "<root><text>a&amp;b</text></root>");
    defer de.freeAllocated(T, value, allocator);
    try testing.expectEqualStrings("a&b", value.text);
}
test "XML entity allocation errors propagate" {
    try testing.checkAllAllocationFailures(alloc, xmlEntityPaths, .{});
}

test "invalid UTF-8 is rejected in skipped strings and enum names" {
    const T = struct { value: i32 };
    try testing.expectError(error.InvalidUnicode, serde.json.fromSlice(T, alloc, "{\"value\":1,\"skip\":\"\xff\"}"));
    const E = enum { ok };
    try testing.expectError(error.InvalidUnicode, serde.json.fromSlice(E, alloc, "\"\xc0\xaf\""));
    const text = try serde.json.fromSlice([]const u8, alloc, "\"日本語 é\"");
    defer alloc.free(text);
    try testing.expectEqualStrings("日本語 é", text);
}

test "flatten inherits parent defaults and cleans up partial overrides" {
    const T = struct {
        nested: struct { text: []const u8, count: i32 } = .{ .text = "static", .count = 8 },
        required: bool,
        pub const serde = .{ .flatten = &.{"nested"} };
    };
    const value = try serde.json.fromSlice(T, alloc, "{\"required\":true}");
    defer de.freeAllocated(T, value, alloc);
    try testing.expectEqualStrings("static", value.nested.text);
    try testing.expectEqual(@as(i32, 8), value.nested.count);
    try testing.expectError(error.MissingField, serde.json.fromSlice(T, alloc, "{\"text\":\"owned\"}"));
}

const WideRecord = struct {
    f0: i32 = 0,
    f1: i32 = 0,
    f2: i32 = 0,
    f3: i32 = 0,
    f4: i32 = 0,
    f5: i32 = 0,
    f6: i32 = 0,
    f7: i32 = 0,
    f8: i32 = 0,
    f9: i32 = 0,
    f10: i32 = 0,
    f11: i32 = 0,
    f12: i32 = 0,
    f13: i32 = 0,
    f14: i32 = 0,
    f15: i32 = 0,
    f16: i32 = 0,
    f17: i32 = 0,
    f18: i32 = 0,
    f19: i32 = 0,
    f20: i32 = 0,
    f21: i32 = 0,
    f22: i32 = 0,
    f23: i32 = 0,
    f24: i32 = 0,
    f25: i32 = 0,
    f26: i32 = 0,
    f27: i32 = 0,
    f28: i32 = 0,
    f29: i32 = 0,
    f30: i32 = 0,
    f31: i32 = 0,
    f32: i32 = 0,
    f33: i32 = 0,
    f34: i32 = 0,
    f35: i32 = 0,
    f36: i32 = 0,
    f37: i32 = 0,
    f38: i32 = 0,
    text: []const u8 = "default",
    pub const serde = .{ .alias = .{ .text = &.{"label"} } };
};
fn wideRecordPaths(allocator: std.mem.Allocator) !void {
    const value = WideRecord{
        .f0 = 1,
        .f1 = 2,
        .f2 = 3,
        .f3 = 4,
        .f4 = 5,
        .f5 = 6,
        .f6 = 7,
        .f7 = 8,
        .f8 = 9,
        .f9 = 10,
        .f10 = 11,
        .f11 = 12,
        .f12 = 13,
        .f13 = 14,
        .f14 = 15,
        .f15 = 16,
        .f16 = 17,
        .f17 = 18,
        .f18 = 19,
        .f19 = 20,
        .f20 = 21,
        .f21 = 22,
        .f22 = 23,
        .f23 = 24,
        .f24 = 25,
        .f25 = 26,
        .f26 = 27,
        .f27 = 28,
        .f28 = 29,
        .f29 = 30,
        .f30 = 31,
        .f31 = 32,
        .f32 = 33,
        .f33 = 34,
        .f34 = 35,
        .f35 = 36,
        .f36 = 37,
        .f37 = 38,
        .f38 = 39,
        .text = "owned",
    };
    const bytes = serde.json.toSlice(allocator, value) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    defer allocator.free(bytes);
    const roundtrip = try serde.json.fromSlice(WideRecord, allocator, bytes);
    defer de.freeAllocated(WideRecord, roundtrip, allocator);
    try testing.expectEqualDeep(value, roundtrip);
    const alias = try serde.json.fromSlice(WideRecord, allocator, "{\"label\":\"alias\",\"f38\":39,\"extra\":[1,2]}");
    defer de.freeAllocated(WideRecord, alias, allocator);
    try testing.expectEqualStrings("alias", alias.text);
    try testing.expectEqual(@as(i32, 39), alias.f38);
}
test "wide field table preserves indices aliases and failure cleanup" {
    try testing.checkAllAllocationFailures(alloc, wideRecordPaths, .{});
    try testing.expectError(error.DuplicateField, serde.json.fromSlice(WideRecord, alloc, "{\"text\":\"first\",\"label\":\"second\"}"));
}

const ObjectAdapter = struct {
    const Wire = struct { wire: i32 };
    pub fn serialize(value: anytype, s: anytype) @TypeOf(s.*).Error!void {
        return serde.core.serialize(Wire, .{ .wire = value.n }, s, .{});
    }
    pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!T {
        const value = try serde.core.deserialize(Wire, allocator, d, .{});
        return .{ .n = value.wire };
    }
};
const HookPayload = struct {
    n: i32,
    pub fn zerdeSerialize(self: @This(), s: anytype) @TypeOf(s.*).Error!void {
        return ObjectAdapter.serialize(self, s);
    }
    pub fn zerdeDeserialize(comptime T: type, allocator: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!T {
        return ObjectAdapter.deserialize(T, allocator, d);
    }
};
fn internalAdapterPaths(allocator: std.mem.Allocator) !void {
    return internalAdapterPathsInner(allocator) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}
fn internalAdapterPathsInner(allocator: std.mem.Allocator) !void {
    inline for (.{ AdaptedInt, HookPayload }) |Payload| {
        const T = union(enum) {
            value: Payload,
            pub const serde = .{ .tag = .internal, .tag_field = "kind" };
        };
        const adapters = .{ .{ AdaptedInt, ObjectAdapter }, .{ HookPayload, IntAdapter } };
        const parsed = try serde.json.fromSliceWithMap(T, allocator, "{\"wire\":7,\"kind\":\"value\"}", adapters);
        try testing.expectEqual(@as(i32, 7), parsed.value.n);
        const bytes = try serde.json.toSliceWithMap(allocator, parsed, adapters);
        defer allocator.free(bytes);
        try testing.expectEqualStrings("{\"kind\":\"value\",\"wire\":7}", bytes);
        var writer: serde.compat.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        var s = serde.msgpack.Serializer.init(&writer.writer, allocator);
        try serde.serializeWith(T, parsed, &s, adapters);
        try testing.expectEqual(@as(u8, 0x82), writer.written()[0]);
        var d = serde.msgpack.Deserializer.init(writer.written());
        const value = try serde.deserializeWith(T, allocator, &d, adapters);
        try testing.expectEqual(@as(i32, 7), value.value.n);
        if (comptime Payload == HookPayload) {
            const tree = try serde.Value.fromAny(T, parsed, allocator);
            defer tree.deinit(allocator);
            const converted = try tree.toType(T, allocator);
            try testing.expectEqual(@as(i32, 7), converted.value.n);
        }
    }
}
test "internal union payload adapters and hooks preserve their object representation" {
    try testing.checkAllAllocationFailures(alloc, internalAdapterPaths, .{});
}
