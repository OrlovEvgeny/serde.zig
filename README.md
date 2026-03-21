# serde.zig

[![Build](https://github.com/OrlovEvgeny/serde.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/OrlovEvgeny/serde.zig/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/OrlovEvgeny/serde.zig?label=release)](https://github.com/OrlovEvgeny/serde.zig/releases/latest)
[![Zig](https://img.shields.io/badge/zig-0.15.2-blue)](https://ziglang.org/download/)

Serialization framework for Zig

Uses Zig's comptime reflection (`@typeInfo`) to serialize and deserialize any Zig type across JSON, MessagePack, TOML, YAML, XML, ZON, and CSV without macros, code generation, or runtime type information.

```zig
const serde = @import("serde");

const User = struct {
    name: []const u8,
    age: u32,
    email: ?[]const u8 = null,
};

// Serialize to JSON
const json_bytes = try serde.json.toSlice(allocator, User{
    .name = "Alice",
    .age = 30,
    .email = "alice@example.com",
});
// => {"name":"Alice","age":30,"email":"alice@example.com"}

// Deserialize from JSON
const user = try serde.json.fromSlice(User, allocator, json_bytes);
```

## Installation

Latest version from master:

```sh
zig fetch --save git+https://github.com/OrlovEvgeny/serde.zig
```

Specific release:

```sh
zig fetch --save https://github.com/OrlovEvgeny/serde.zig/archive/refs/tags/v0.1.2.tar.gz
```

Then in your `build.zig`:

```zig
const serde_dep = b.dependency("serde", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("serde", serde_dep.module("serde"));
```

Requires Zig 0.15.0 or later.

## Formats

| Format | Module | Serialize | Deserialize |
|--------|--------|-----------|-------------|
| JSON | `serde.json` | + | + |
| MessagePack | `serde.msgpack` | + | + |
| TOML | `serde.toml` | + | + |
| YAML | `serde.yaml` | + | + |
| XML | `serde.xml` | + | + |
| ZON | `serde.zon` | + | + |
| CSV | `serde.csv` | + | + |

Every format exposes the same API:

```zig
// Serialization
const bytes = try serde.json.toSlice(allocator, value);
try serde.json.toWriter(&writer, value);

// Deserialization
const val = try serde.json.fromSlice(T, allocator, bytes);
const val = try serde.json.fromReader(T, allocator, &reader);
```

## Supported Types

- `bool`, `i8`..`i128`, `u8`..`u128`, `f16`..`f128`
- `[]const u8`, `[]u8`, `[:0]const u8` (strings)
- `?T` (optionals, serialized as value or null)
- `[N]T` (fixed-length arrays)
- `[]T`, `[]const T` (slices)
- Structs with named fields, nested arbitrarily
- Tuples (`struct { i32, bool }`, serialized as arrays)
- Enums (as string name or integer)
- Tagged unions (`union(enum)`, four tagging styles)
- `*T`, `*const T` (pointers, followed transparently)
- `std.StringHashMap(V)` (maps)
- `void` (serialized as null)

## Examples

### Nested structs

```zig
const Address = struct {
    street: []const u8,
    city: []const u8,
    zip: []const u8,
};

const Person = struct {
    name: []const u8,
    age: u32,
    address: Address,
    tags: []const []const u8,
};

const person = Person{
    .name = "Bob",
    .age = 25,
    .address = .{ .street = "123 Main St", .city = "Springfield", .zip = "62704" },
    .tags = &.{ "admin", "active" },
};

const json = try serde.json.toSlice(allocator, person);
const msgpack = try serde.msgpack.toSlice(allocator, person);
const yaml = try serde.yaml.toSlice(allocator, person);
const xml = try serde.xml.toSlice(allocator, person);
```

### Arena allocator (recommended for deserialization)

Deserialization allocates memory for strings, slices, and nested structures. Use an `ArenaAllocator` for easy cleanup:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const user = try serde.json.fromSlice(User, arena.allocator(), json_bytes);
```

### Zero-copy deserialization

When strings in the JSON input contain no escape sequences, `fromSliceBorrowed` returns slices pointing directly into the input buffer:

```zig
const input = "{\"name\":\"alice\",\"id\":1}";
const msg = try serde.json.fromSliceBorrowed(Msg, allocator, input);
// msg.name points into input, input must outlive msg
```

### Pretty-printed output

```zig
const pretty = try serde.json.toSliceWith(allocator, value, .{ .pretty = true, .indent = 2 });
// {
//   "name": "Alice",
//   "age": 30
// }
```

### Tagged unions

```zig
const Command = union(enum) {
    ping: void,
    execute: struct { query: []const u8 },
    quit: void,
};

const cmd = Command{ .execute = .{ .query = "SELECT 1" } };
const bytes = try serde.json.toSlice(allocator, cmd);
// => {"execute":{"query":"SELECT 1"}}
```

### Enums

```zig
const Color = enum { red, green, blue };

const bytes = try serde.json.toSlice(allocator, Color.blue);
// => "blue"

const color = try serde.json.fromSlice(Color, allocator, bytes);
// => Color.blue
```

### Maps

```zig
var map = std.StringHashMap(i32).init(allocator);
defer map.deinit();
try map.put("a", 1);
try map.put("b", 2);

const bytes = try serde.json.toSlice(allocator, map);
// => {"a":1,"b":2}
```

### CSV

```zig
const Record = struct {
    name: []const u8,
    age: u32,
    active: bool,
};

const records: []const Record = &.{
    .{ .name = "Alice", .age = 30, .active = true },
    .{ .name = "Bob", .age = 25, .active = false },
};

const csv_bytes = try serde.csv.toSlice(allocator, records);
// name,age,active
// Alice,30,true
// Bob,25,false
```

### TOML

```zig
const Config = struct {
    title: []const u8,
    port: u16 = 8080,
    database: struct {
        host: []const u8,
        name: []const u8,
    },
};

const cfg = try serde.toml.fromSlice(Config, arena.allocator(),
    \\title = "myapp"
    \\port = 3000
    \\
    \\[database]
    \\host = "localhost"
    \\name = "mydb"
);
```

### YAML

```zig
const Server = struct {
    host: []const u8,
    port: u16,
    debug: bool,
};

const yaml_input =
    \\host: localhost
    \\port: 8080
    \\debug: true
;

const server = try serde.yaml.fromSlice(Server, arena.allocator(), yaml_input);

const yaml_bytes = try serde.yaml.toSlice(allocator, server);
// host: localhost
// port: 8080
// debug: true
```

### XML

```zig
const User = struct {
    id: u64,
    name: []const u8,
    role: []const u8,

    pub const serde = .{
        .xml_attribute = .{.id},
        .xml_root = "user",
    };
};

const xml_bytes = try serde.xml.toSlice(allocator, User{
    .id = 42,
    .name = "Alice",
    .role = "admin",
});
// <?xml version="1.0" encoding="UTF-8"?>
// <user id="42"><name>Alice</name><role>admin</role></user>

const user = try serde.xml.fromSlice(User, arena.allocator(), xml_bytes);
```

Fields listed in `xml_attribute` are serialized as XML attributes on the root element. All other fields become child elements.

### ZON

Produces valid `.zon` files:

```zig
const bytes = try serde.zon.toSlice(allocator, Config{
    .title = "myapp",
    .port = 3000,
    .database = .{ .host = "localhost", .name = "mydb" },
});
// .{
//     .title = "myapp",
//     .port = 3000,
//     .database = .{
//         .host = "localhost",
//         .name = "mydb",
//     },
// }
```

## Serde Options

Customize serialization behavior by declaring `pub const serde` on your types. All options are resolved at comptime.

### Field renaming

```zig
const User = struct {
    user_id: u64,
    first_name: []const u8,
    last_name: []const u8,

    pub const serde_options = .{
        .rename = .{ .user_id = "id" },
        .rename_all = serde.NamingConvention.camel_case,
    };
};

// Serializes as: {"id":1,"firstName":"Alice","lastName":"Smith"}
```

Available conventions: `.camel_case`, `.snake_case`, `.pascal_case`, `.kebab_case`, `.SCREAMING_SNAKE_CASE`.

### Skip fields

```zig
const Secret = struct {
    name: []const u8,
    token: []const u8,
    email: ?[]const u8,
    tags: []const []const u8,

    pub const serde = .{
        .skip = .{
            .token = serde.SkipMode.always,
            .email = serde.SkipMode.@"null",
            .tags = serde.SkipMode.empty,
        },
    };
};
```

### Default values

Zig's struct default values are used during deserialization when a field is absent from the input:

```zig
const Config = struct {
    name: []const u8,
    retries: i32 = 3,
    timeout: i32 = 30,
};

const cfg = try serde.json.fromSlice(Config, allocator, "{\"name\":\"app\"}");
// cfg.retries == 3, cfg.timeout == 30
```

### Deny unknown fields

```zig
const Strict = struct {
    x: i32,
    pub const serde = .{
        .deny_unknown_fields = true,
    };
};
// Returns error.UnknownField if input contains unexpected keys
```

### Flatten nested structs

```zig
const Metadata = struct {
    created_by: []const u8,
    version: i32 = 1,
};

const User = struct {
    name: []const u8,
    meta: Metadata,

    pub const serde = .{
        .flatten = &[_][]const u8{"meta"},
    };
};

// Serializes as: {"name":"Alice","created_by":"admin","version":2}
// instead of:    {"name":"Alice","meta":{"created_by":"admin","version":2}}
```

### Union tagging styles

```zig
const Command = union(enum) {
    ping: void,
    execute: struct { query: []const u8 },

    pub const serde_options = .{
        // .external (default): {"execute":{"query":"SELECT 1"}}
        // .internal:           {"type":"execute","query":"SELECT 1"}
        // .adjacent:           {"type":"execute","content":{"query":"SELECT 1"}}
        // .untagged:           {"query":"SELECT 1"}
        .tag = serde.UnionTag.internal,
        .tag_field = "type",
    };
};
```

### Enum representation

```zig
const Status = enum(u8) {
    active = 0,
    inactive = 1,
    pending = 2,

    pub const serde_options = .{
        .enum_repr = serde.EnumRepr.integer, // serialize as 0, 1, 2
    };
};
// Default is .string: "active", "inactive", "pending"
```

### Per-field custom serialization

```zig
const Event = struct {
    name: []const u8,
    created_at: i64,

    pub const serde_options = .{
        .with = .{
            .created_at = serde.helpers.UnixTimestampMs,
        },
    };
};
```

Built-in helpers: `serde.helpers.UnixTimestamp`, `serde.helpers.UnixTimestampMs`, `serde.helpers.Base64`.

## Out-of-Band Schema

Override serialization behavior externally, without modifying the type. Useful for third-party types you don't control, or when the same type needs different wire representations in different contexts.

```zig
const Point = struct { x: f64, y: f64, z: f64 };

// External schema: rename fields, skip z
const schema = .{
    .rename = .{ .x = "X", .y = "Y" },
    .skip = .{ .z = serde.SkipMode.always },
};

const point = Point{ .x = 1.0, .y = 2.0, .z = 3.0 };

// Serialize with schema
const bytes = try serde.json.toSliceSchema(allocator, point, schema);
// => {"X":1.0e0,"Y":2.0e0}

// Deserialize with schema
const p = try serde.json.fromSliceSchema(Point, allocator, bytes, schema);
// p.x == 1.0, p.y == 2.0, p.z == 0.0 (default)
```

The same type can be serialized differently with different schemas:

```zig
const full_schema = .{
    .rename_all = serde.NamingConvention.SCREAMING_SNAKE_CASE,
};

const compact_schema = .{
    .rename = .{ .x = "a", .y = "b" },
    .skip = .{ .z = serde.SkipMode.always },
};

const full = try serde.json.toSliceSchema(allocator, point, full_schema);
// => {"X":1.0e0,"Y":2.0e0,"Z":3.0e0}

const compact = try serde.json.toSliceSchema(allocator, point, compact_schema);
// => {"a":1.0e0,"b":2.0e0}
```

Schema supports all the same options as `pub const serde`: `rename`, `rename_all`, `skip`, `default`, `with`, `deny_unknown_fields`, `flatten`, `tag`, `tag_field`, `content_field`, `enum_repr`.

When both an external schema and `pub const serde` exist on a type, the external schema takes priority.

All `*Schema` variants are available on every format module: `toSliceSchema`, `toWriterSchema`, `fromSliceSchema`, `fromReaderSchema`, etc.

## Out-of-Band Type Overrides

Override how specific types are serialized/deserialized at the call site, without modifying the type. This is useful for third-party types you don't own (e.g. `std.ArrayList`, external library structs) or when you need a one-off representation.

Pass a comptime map of `{Type, Adapter}` pairs to the `*WithMap` functions:

```zig
const std = @import("std");
const serde = @import("serde");

// A type from a library you don't control
const Timestamp = struct {
    seconds: i64,
    nanos: u32,
};

// Define how to serialize/deserialize it
const TimestampAdapter = struct {
    pub fn serialize(value: Timestamp, s: anytype) @TypeOf(s.*).Error!void {
        // Serialize as a single float: seconds.nanos
        const ms: f64 = @as(f64, @floatFromInt(value.seconds)) +
            @as(f64, @floatFromInt(value.nanos)) / 1_000_000_000.0;
        try s.serializeFloat(ms);
    }

    pub fn deserialize(
        comptime _: type,
        _: std.mem.Allocator,
        d: anytype,
    ) @TypeOf(d.*).Error!Timestamp {
        const val = try d.deserializeFloat(f64);
        const secs: i64 = @intFromFloat(val);
        const nanos: u32 = @intFromFloat((val - @as(f64, @floatFromInt(secs))) * 1_000_000_000.0);
        return .{ .seconds = secs, .nanos = nanos };
    }
};

// Build the map and use it
const map = .{ .{ Timestamp, TimestampAdapter } };

const Event = struct {
    name: []const u8,
    at: Timestamp,
};

const event = Event{
    .name = "deploy",
    .at = .{ .seconds = 1700000000, .nanos = 500000000 },
};

const bytes = try serde.json.toSliceWithMap(allocator, event, map);
// => {"name":"deploy","at":1700000000.5}

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const result = try serde.json.fromSliceWithMap(Event, arena.allocator(), bytes, map);
// result.at.seconds == 1700000000, result.at.nanos == 500000000
```

### How it works

The map is a comptime tuple where each entry is `.{ TargetType, AdapterModule }`. The adapter module must provide:

- `fn serialize(value: T, s: anytype) !void` -- writes the value to the serializer
- `fn deserialize(comptime T: type, allocator: Allocator, d: anytype) !T` -- reads the value from the deserializer

When serde encounters a type that matches a map entry, it calls the adapter instead of the default comptime-derived serialization. The check happens at every level: top-level values, struct fields, array elements, optional contents, and union payloads.

### Available functions

Every format module provides map-aware variants:

```zig
// Serialize
const bytes = try serde.json.toSliceWithMap(allocator, value, map);
try serde.json.toWriterWithMap(&writer, value, map);

// Deserialize
const val = try serde.json.fromSliceWithMap(T, allocator, bytes, map);
const val = try serde.json.fromSliceBorrowedWithMap(T, allocator, bytes, map);
const val = try serde.json.fromReaderWithMap(T, allocator, &reader, map);
```

For more control, use the core functions directly:

```zig
try serde.serializeWith(T, value, &serializer, map);
const val = try serde.deserializeWith(T, allocator, &deserializer, map);
```

### Precedence

When multiple customization mechanisms apply to the same type:

1. `zerdeSerialize` / `zerdeDeserialize` on the type itself (highest priority)
2. Out-of-band map entry
3. Default comptime-derived behavior (lowest priority

### Example: `std.ArrayList(u8)` as string

```zig
const ArrayListAdapter = struct {
    pub fn serialize(value: std.ArrayList(u8), s: anytype) @TypeOf(s.*).Error!void {
        try s.serializeString(value.items);
    }

    pub fn deserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        d: anytype,
    ) @TypeOf(d.*).Error!std.ArrayList(u8) {
        const str = try d.deserializeString(allocator);
        var list = std.ArrayList(u8).empty;
        // steal the allocated string buffer
        list.items = @constCast(str);
        list.capacity = str.len;
        list.items.len = str.len;
        return list;
    }
};

const map = .{ .{ std.ArrayList(u8), ArrayListAdapter } };

const Response = struct {
    status: u16,
    body: std.ArrayList(u8),
};

const resp = Response{
    .status = 200,
    .body = blk: {
        var b = std.ArrayList(u8).empty;
        try b.appendSlice(allocator, "OK");
        break :blk b;
    },
};

const bytes = try serde.json.toSliceWithMap(allocator, resp, map);
// => {"status":200,"body":"OK"}
// Without the map, body would serialize as {"items":"OK","capacity":N,"items.len":2}
```

## Custom Serialization

For full control, declare `zerdeSerialize` and/or `zerdeDeserialize` on your type:

```zig
const StringWrappedU64 = struct {
    inner: u64,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.inner}) catch unreachable;
        try serializer.serializeString(s);
    }

    pub fn zerdeDeserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        deserializer: anytype,
    ) @TypeOf(deserializer.*).Error!@This() {
        const str = try deserializer.deserializeString(allocator);
        defer allocator.free(str);
        return .{ .inner = std.fmt.parseInt(u64, str, 10) catch return error.InvalidNumber };
    }
};

const bytes = try serde.json.toSlice(allocator, StringWrappedU64{ .inner = 12345 });
// => "12345"
```

## Error Handling

Deserialization returns specific errors:

- `error.UnexpectedToken` -- malformed input
- `error.UnexpectedEof` -- input ended prematurely
- `error.MissingField` -- required struct field absent
- `error.UnknownField` -- unexpected field (with `deny_unknown_fields`)
- `error.InvalidNumber` -- number parse failure or overflow
- `error.WrongType` -- input type doesn't match target type
- `error.DuplicateField` -- same field appears twice

```zig
const result = serde.json.fromSlice(Config, allocator, input) catch |err| switch (err) {
    error.MissingField => std.debug.print("missing required field\n", .{}),
    error.UnexpectedEof => std.debug.print("truncated input\n", .{}),
    else => return err,
};
```

## Tests

```sh
zig build test
```

## License

[MIT](LICENSE)
