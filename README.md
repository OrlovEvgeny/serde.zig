# serde.zig

[![Build](https://github.com/OrlovEvgeny/serde.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/OrlovEvgeny/serde.zig/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/OrlovEvgeny/serde.zig?label=release)](https://github.com/OrlovEvgeny/serde.zig/releases/latest)
[![Zig](https://img.shields.io/badge/zig-0.15.2%20%7C%200.16.0%20%7C%200.17--dev-blue)](https://ziglang.org/download/)

Serialization framework for Zig

Uses Zig's comptime reflection (`@typeInfo`) to serialize and deserialize any Zig type across JSON, MessagePack, Erlang ETF, TOML, YAML, XML, ZON, TOON, and CSV without macros, code generation, or runtime type information.

## Table of Contents

- [Why serde.zig?](#why-serdezig)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Formats](#formats)
- [Supported Types](#supported-types)
- [Erlang ETF / OTP 29](#erlang-etf--otp-29)
- [Examples](#examples)
  - [Nested structs](#nested-structs)
  - [Arena allocator](#arena-allocator-recommended-for-deserialization)
  - [Zero-copy deserialization](#zero-copy-deserialization)
  - [Pretty-printed output](#pretty-printed-output)
  - [Tagged unions](#tagged-unions)
  - [Enums](#enums)
  - [Maps](#maps)
  - [CSV](#csv)
  - [TOML](#toml)
  - [YAML](#yaml)
  - [XML](#xml)
  - [ZON](#zon)
  - [TOON](#toon)
- [Serde Options](#serde-options)
  - [Field renaming](#field-renaming)
  - [Asymmetric renaming](#asymmetric-renaming)
  - [Field aliases](#field-aliases)
  - [Enum and union variant renaming](#enum-and-union-variant-renaming)
  - [Skip fields](#skip-fields)
  - [Default values](#default-values)
  - [Deny unknown fields](#deny-unknown-fields)
  - [Flatten nested structs](#flatten-nested-structs)
  - [Union tagging styles](#union-tagging-styles)
  - [Enum representation](#enum-representation)
  - [Per-field custom serialization](#per-field-custom-serialization)
- [Out-of-Band Schema](#out-of-band-schema)
- [Out-of-Band Type Overrides](#out-of-band-type-overrides)
- [Custom Serialization](#custom-serialization)
- [Error Handling](#error-handling)
- [Performance](#performance)
- [Tests](#tests)
- [License](#license)

## Why serde.zig?

**No boilerplate.** No macros, no code generation, no build steps. Just declare a struct and serialize it. Zig's comptime reflection handles everything at compile time.

**Nine formats, one API.** JSON, MessagePack, Erlang ETF, TOML, YAML, XML, ZON, TOON, and CSV share the same `toSlice`/`fromSlice`/`toWriter`/`fromReader` shape. Learn once, use everywhere.

**Out-of-band schemas.** Serialize the same type differently in different contexts without modifying the type itself. Essential for third-party types and API versioning.

**Zero-copy JSON.** `fromSliceBorrowed` returns string slices that point directly into the input buffer when no escape sequences are present. No allocation, no copying.

**Comptime validation.** Invalid types, missing fields, and incorrect option names are caught at compile time, not at runtime.

## Quick Start

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
zig fetch --save https://github.com/OrlovEvgeny/serde.zig/archive/refs/tags/v1.1.0.tar.gz
```

Then in your `build.zig`:

```zig
const serde_dep = b.dependency("serde", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("serde", serde_dep.module("serde"));
```

Requires Zig 0.15.2 or later, including current Zig 0.17 development builds.

Supported Zig versions:

| Zig version           | Status                                                            |
| --------------------- | ----------------------------------------------------------------- |
| `0.16.0`              | current stable, required in docs CI                               |
| `0.15.2`              | previous stable, fully supported                                  |
| `0.17-dev` / `master` | supported against current development snapshots and tracked in CI |

## Formats

| Format              | Module          | Serialize | Deserialize |
| ------------------- | --------------- | --------- | ----------- |
| JSON                | `serde.json`    | +         | +           |
| MessagePack         | `serde.msgpack` | +         | +           |
| Erlang ETF / OTP 29 | `serde.etf`     | +         | +           |
| TOML                | `serde.toml`    | +         | +           |
| YAML                | `serde.yaml`    | +         | +           |
| XML                 | `serde.xml`     | +         | +           |
| ZON                 | `serde.zon`     | +         | +           |
| TOON                | `serde.toon`    | +         | +           |
| CSV                 | `serde.csv`     | +         | +           |

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
const toon = try serde.toon.toSlice(allocator, person);
```

### Managed parsing and memory ownership

Every format provides `fromSliceManaged(T, allocator, input)` and
`fromSliceManagedSchema(T, allocator, input, schema)`. They return `serde.Parsed(T)`:

```zig
var parsed = try serde.json.fromSliceManaged(User, allocator, json_bytes);
defer parsed.deinit();
useUser(parsed.value);
```

The result owns a separate arena with a stable address, including allocations
made by custom adapters through their provided arena allocator. Move the result freely,
but keep one owner and call `deinit` exactly once. Do not separately free its
fields. This API owns allocated output independently of the input; static Zig
and schema defaults remain static. It does not close resources such as files
opened by custom hooks.

Existing `fromSlice` signatures are unchanged. They allocate strings and
containers with the caller's allocator; an arena remains convenient for batch
parsing:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const user = try serde.json.fromSlice(User, arena.allocator(), json_bytes);
```

For ordinary derived values, `serde.core.freeAllocated(T, value, allocator)`
recursively frees owned output and preserves defaults; use
`freeAllocatedSchema` when parsing with an external schema. Prefer managed
parsing or your own arena for custom types whose ownership cannot be inferred
from their fields. A nonallocating field `with.deserialize` may retain its wire
value; an allocating `with.deserializeAlloc` must produce an independent result.

Formats retain their root restrictions and writer signatures: CSV reads rows
into a slice of structs, TOML reads a struct/table, and XML adds a root element.
Managed parsing does not change these representations. `fromReader` variants
own their temporary input buffers and release them after conversion.

### Zero-copy deserialization

When strings in the JSON input contain no escape sequences, `fromSliceBorrowed` returns slices pointing directly into the input buffer:

```zig
const input = "{\"name\":\"alice\",\"id\":1}";
const msg = try serde.json.fromSliceBorrowed(Msg, allocator, input);
// msg.name points into input, input must outlive msg
```

Borrowed JSON requires the input to outlive the result. Escaped strings are
rejected with `InvalidEscape`; the API does not silently allocate replacements.
This applies inside arrays and nested containers too. Use a separate arena for
container metadata, and do not pass borrowed results to `freeAllocated`.

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

### TOON

Produces compact TOON documents for the JSON data model:

```zig
const bytes = try serde.toon.toSlice(allocator, Config{
    .title = "myapp",
    .port = 3000,
    .database = .{ .host = "localhost", .name = "mydb" },
});
// title: myapp
// port: 3000
// database:
//   host: localhost
//   name: mydb
```

## Erlang ETF / OTP 29

`serde.etf` supports the current [External Term Format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html) and the connected-message portion of the [OTP 29 Distribution Protocol](https://www.erlang.org/docs/29/apps/erts/erl_dist_protocol.html), including legacy input tags, arbitrary bignums, improper lists, bit-binaries, maps with term keys, process identities, funs, exports, opaque top-level `LOCAL_EXT`, and OTP 29 native `RECORD_EXT`. It offers two APIs:

- Typed serialization for ordinary Zig values, with the same rename, skip, flatten, union, schema, and custom-adapter rules as the other formats.
- An owning `Term` model for exact Erlang semantics, with `deinit`, `clone`, and semantic `eql`.

### Typed mapping

| Zig value | Canonical ETF output |
|-----------|----------------------|
| `bool` | atoms `true` / `false` |
| `null`, `void`, empty optional | atom `null` |
| byte strings | `BINARY_EXT` |
| integers | smallest integer or bignum tag |
| floats | finite `NEW_FLOAT_EXT` |
| arrays, slices, tuples | proper ETF lists |
| structs and maps | `MAP_EXT` |
| field, enum, union names | binary |

The default decoder accepts common Erlang and Elixir representations: `null`, `nil`, `undefined`, and `NIL_EXT` can become Zig null; binary, `STRING_EXT`, and byte-lists can become strings; names may be atoms or binaries; and sequences may be proper lists or tuples. Set `.strict = true` to accept only the canonical profile.

```zig
const wire = try serde.etf.toSliceWith(allocator, config, .{
    .compression = .{ .threshold = 1024 },
    .zlib_level = 6,
});
defer allocator.free(wire);

const decoded = try serde.etf.fromSliceWith(Config, allocator, wire, .{
    .strict = true,
});
```

### Exact `Term` API

All decoded slices and nested terms are owned by the allocator passed to `decodeTerm`.

```zig
var term = try serde.etf.decodeTerm(allocator, bytes, .{});
defer term.deinit(allocator);

var copy = try term.clone(allocator);
defer copy.deinit(allocator);

const canonical = try serde.etf.encodeTerm(allocator, term, .{});
defer allocator.free(canonical);
```

Legacy float/atom/pid/port/reference and compact number/tuple tags normalize to modern semantic values. Latin-1 atoms normalize to UTF-8. `legacy_fun` requires `.allow_legacy = true` when writing, and opaque `local` requires `.allow_local = true`. NaN and infinity are rejected.

### Compression and limits

`COMPRESSED_EXT` is decoded automatically with its zlib checksum verified. Encoding supports `.never` (default), `.always`, and `.threshold`; `zlib_level` 0 stores the payload uncompressed while 1-9 trade speed for ratio. Defensive defaults apply to both dynamic and typed APIs:

- 10 MiB input/output and uncompressed term size
- depth 256
- 1,000,000 collection elements
- 1 MiB bignum magnitude

All limits are configurable through `EncodeOptions` and `DecodeOptions`. Length arithmetic is checked before allocation.

### Distribution codec

`serde.etf.distribution` provides negotiated capability flags, independent 2048-entry send/receive atom caches, 4-byte framing, ticks, typed control operation variants, and OTP fragmentation/reassembly.

```zig
const dist = serde.etf.distribution;
const caps = dist.CapabilityFlags{
    .bits = dist.CapabilityFlags.dist_hdr_atom_cache |
        dist.CapabilityFlags.utf8_atoms |
        dist.CapabilityFlags.fragments,
};

var decoder = dist.Decoder.init(allocator, caps, .{});
defer decoder.deinit();

try decoder.feed(network_chunk); // chunks may split headers or frames
while (try decoder.next()) |message_value| {
    var message = message_value;
    defer message.deinit(allocator);
    // message is .tick or .data.{ control, payload }
}
```

The encoder checks negotiated flags before spawn, payload-exit, unlink-id, alias, alternate-action, fragmentation, or native-record use. The decoder limits frames/reassembled messages to 10 MiB, concurrent fragment sequences to 64, and fragments per sequence to 1024 by default. Legacy pass-through type 112 is accepted.

This module begins after a distribution handshake. EPMD, node handshakes, cookies, TCP/TLS, reconnection, and a ready-made Erlang node client are intentionally out of scope.

## Serde Options

Customize serialization behavior by declaring `pub const serde` on your types. All options are resolved at comptime.

### Field renaming

```zig
const User = struct {
    user_id: u64,
    first_name: []const u8,
    last_name: []const u8,

    pub const serde = .{
        .rename = .{ .user_id = "id" },
        .rename_all = serde.NamingConvention.camel_case,
    };
};

// Serializes as: {"id":1,"firstName":"Alice","lastName":"Smith"}
```

Available conventions: `.camel_case`, `.snake_case`, `.pascal_case`, `.kebab_case`, `.SCREAMING_SNAKE_CASE`.

### Asymmetric renaming

Use different names for serialization and deserialization. This is essential for API evolution, rolling upgrades, and interoperating with systems that use different naming conventions for input vs output.

```zig
const User = struct {
    user_id: u64,
    first_name: []const u8,

    pub const serde = .{
        // Serialize as "id", but accept "user_id" on input
        .rename_serialize = .{ .user_id = "id" },
        // Different case conventions per direction
        .rename_all_serialize = serde.NamingConvention.camel_case,
        .rename_all_deserialize = serde.NamingConvention.snake_case,
    };
};

// Serializes as: {"id":42,"firstName":"Alice"}
// Deserializes from: {"user_id":42,"first_name":"Alice"}
```

Direction-specific options (`rename_serialize`, `rename_deserialize`, `rename_all_serialize`, `rename_all_deserialize`) take priority over their symmetric counterparts (`rename`, `rename_all`).

### Field aliases

Accept multiple input names for a single field during deserialization. Aliases do not affect serialization output. Useful for backward compatibility when field names change across API versions.

```zig
const Config = struct {
    endpoint: []const u8,

    pub const serde = .{
        .alias = .{ .endpoint = &.{ "url", "uri", "addr" } },
    };
};

// All of these deserialize into .endpoint:
// {"endpoint": "..."}, {"url": "..."}, {"uri": "..."}, {"addr": "..."}
// Serializes as: {"endpoint": "..."}
```

Aliases work together with rename and rename_all:

```zig
const User = struct {
    user_id: u64,

    pub const serde = .{
        .rename = .{ .user_id = "id" },
        .alias = .{ .user_id = &.{ "user_id", "userId", "uid" } },
    };
};

// Primary name: "id" (from rename)
// Also accepts: "user_id", "userId", "uid" (from alias)
// Serializes as: {"id": 42}
```

### Enum and union variant renaming

Rename and alias options also apply to enum values and union variant tags:

```zig
const Status = enum {
    active,
    inactive,
    in_review,

    pub const serde = .{
        .rename_all_serialize = serde.NamingConvention.SCREAMING_SNAKE_CASE,
        .rename_all_deserialize = serde.NamingConvention.SCREAMING_SNAKE_CASE,
        .alias = .{ .in_review = &.{ "in_review", "pending_review" } },
    };
};

// Serializes as: "IN_REVIEW"
// Accepts: "IN_REVIEW", "in_review", "pending_review"
```

```zig
const Command = union(enum) {
    ping: void,
    execute: struct { query: []const u8 },

    pub const serde = .{
        .tag = serde.UnionTag.internal,
        .tag_field = "type",
        .rename = .{ .execute = "exec" },
        .alias = .{ .execute = &.{ "execute", "run" } },
    };
};

// Serializes as: {"type":"exec","query":"SELECT 1"}
// Accepts: "exec", "execute", "run" as variant tag values
```

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

Directional skip maps can be used in `pub const serde` or an external schema:

```zig
pub const serde = .{
    .skip_serializing = .{ .secret = true },
    .skip_deserializing = .{ .computed = true },
};
```

`skip.always` skips both directions. A schema entry, including explicit `false`,
overrides the corresponding in-type setting. Skipped input fields still need a
Zig/schema default or an optional type to construct the result.

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

Struct input rejects repeated fields with `DuplicateField`, including a primary
name followed by its alias. Maps keep the last value. Recursive `flatten` uses
the nested fields' names, skips, defaults and required-field checks; ambiguous
names or aliases across fields are compile errors. Internal and adjacent union
tags may appear before or after their payload. `Value.fromAny` and `Value.toType`
use the same core field and union rules as format conversion.

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

    pub const serde = .{
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

    pub const serde = .{
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

    pub const serde = .{
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

Schema supports all the same options as `pub const serde`: `rename`, `rename_all`, `rename_serialize`, `rename_deserialize`, `rename_all_serialize`, `rename_all_deserialize`, `alias`, `skip`, `skip_serializing`, `skip_deserializing`, `default`, `with`, `deny_unknown_fields`, `flatten`, `tag`, `tag_field`, `content_field`, `enum_repr`.

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

JSON provides the following map-aware convenience functions (TOON and ETF also
provide format-specific map variants). Other formats use the core functions:

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
3. Default comptime-derived behavior (lowest priority)

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
- `error.InvalidUnicode` -- malformed unicode escape (e.g. lone surrogate)
- `error.InvalidControlCharacter` -- unescaped control char in JSON string
- `error.MaxDepthExceeded` -- JSON nesting deeper than configured limit
- `error.WrongType` -- input type doesn't match target type
- `error.DuplicateField` -- same field appears twice
- `error.FieldCountMismatch` -- CSV row has fewer fields than headers
- `error.MalformedXml` -- structurally invalid XML (e.g. `--` inside comment)
- `error.InvalidYaml` -- structurally invalid YAML

```zig
const result = serde.json.fromSlice(Config, allocator, input) catch |err| switch (err) {
    error.MissingField => std.debug.print("missing required field\n", .{}),
    error.UnexpectedEof => std.debug.print("truncated input\n", .{}),
    else => return err,
};
```

## Deserialize Options

Each format exposes a `fromSliceWith` entry point taking format-specific options.

### JSON (`serde.json.DeserializeOptions`)

```zig
const val = try serde.json.fromSliceWith(Config, allocator, input, .{
    .lenient_null_to_zero = false,             // true: null -> 0 for int/float
    .allow_unescaped_control_chars = false,    // true: accept raw 0x00..0x1f in strings
    .max_depth = 256,                          // raise for very nested input
});
```

Defaults reject behavior that violates RFC 8259. Set `lenient_null_to_zero` to opt
back into pre-fix behavior where JSON `null` silently became `0` for non-optional
numeric fields.

### YAML (`serde.yaml.DeserializeOptions`)

```zig
const val = try serde.yaml.fromSliceWith(Config, allocator, input, .{
    .yaml_11_booleans = false,   // true: yes/no/on/off recognized as booleans
    .strict_indent = false,      // true: error on tab in indentation columns
});
```

Default is YAML 1.2 behavior. Enabling `yaml_11_booleans` brings the "Norway
problem" (`country: NO` -> `false`).

### CSV (`Dialect.strict_field_count`)

```zig
const dialect = serde.csv.Dialect{ .strict_field_count = true };
const rows = try serde.csv.fromSliceWith([]const Row, allocator, input, dialect);
```

Defaults to true: rows with fewer fields than headers produce
`error.FieldCountMismatch`. Set to false to silently fill missing trailing
fields with empty values.

### JSON serializer (`serde.json.Options.escape_js_unsafe`)

```zig
const bytes = try serde.json.toSliceWith(allocator, value, .{ .escape_js_unsafe = true });
```

When true, U+2028 and U+2029 are escaped as `/`. They are valid
JSON characters but illegal in JavaScript string literals; escape when embedding
output in HTML `<script>` tags.

## Migration

`serde.json.fromSlice` is now stricter by default and may reject inputs that
previously parsed silently:

- `null` for a non-optional `i32` / `f64` field now errors. Mark the field
  optional (`?i32`) or pass `.lenient_null_to_zero = true`.
- Trailing, missing, and double commas (`[1,2,]`, `[1 2 3]`, `[1,,2]`) now error.
- Unescaped control characters (raw bytes `0x00..0x1f`) inside JSON strings now
  error. Pass `.allow_unescaped_control_chars = true` to keep parsing them.
- Nesting deeper than 256 levels errors with `error.MaxDepthExceeded`. Raise
  `.max_depth` if you have legitimately deep input.
- JSON `\uDC00` (lone low surrogate) and `\uD83D` (unpaired high surrogate)
  in string escapes now error.

CSV `fromSlice` is also stricter: a data row with fewer fields than the header
errors. Pass a dialect with `.strict_field_count = false` to retain legacy
behavior.

## Performance

```sh
zig build bench
zig build bench -Dbench-format=json -Dbench-compare-std-json=true
zig build bench -Dbench-filter=json -Dbench-out=bench/results.json
```

Results use schema version 3. Each operation reports the median and min/max of
seven samples; allocation counts are measured in a separate probe. `warm` and
`cold` measure complete operations including allocation; these labels control
warmup, not hardware cache flushing. Complete calls use `std.heap.smp_allocator`.
`cpu` uses a retained arena or fixed output buffer. Input generation,
MessagePack encoding for decode tests, and map setup
happen outside measurements. NDJSON measures the actual streaming reader.

The suite includes wide structs, reordered keys and aliases, long and escaped
strings, nested collections, MessagePack and `std.json`. Throughput uses the
actual input/output size. Run with one compiler, target, optimization mode, and
harness for both revisions; avoid concurrent builds. Results from versions 1
and 2 are not comparable and are rejected as baselines.

See [the implementation and benchmark report](docs/core-serde-improvements.md)
for local before/after measurements, reproducible commands, and remaining costs.
CI copies the current harness into the PR base checkout before comparing it.
The default benchmark optimize mode is `ReleaseFast`; `zig build --help` lists
filters, baseline and threshold options.

## Tests

```sh
zig build test
zig build fuzz
# Requires Erlang/OTP 29:
zig build interop
```

## License

[MIT](LICENSE)
