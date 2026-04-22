//! # serde.zig
//!
//! A serialization framework for Zig using comptime reflection to
//! serialize and deserialize any Zig type across multiple formats
//! without macros, code generation, or runtime type information.
//!
//! ## Supported Formats
//!
//! | Module   | Format      |
//! |----------|-------------|
//! | `json`   | JSON        |
//! | `msgpack`| MessagePack |
//! | `toml`   | TOML        |
//! | `yaml`   | YAML        |
//! | `xml`    | XML         |
//! | `csv`    | CSV         |
//! | `zon`    | ZON         |
//!
//! ## Quick Start
//!
//! ```
//! const serde = @import("serde");
//! const json_bytes = try serde.json.toSlice(allocator, my_struct);
//! const result = try serde.json.fromSlice(MyStruct, allocator, json_bytes);
//! ```

pub const core = @import("core/mod.zig");
pub const compat = @import("compat.zig");
pub const json = @import("formats/json/mod.zig");
pub const msgpack = @import("formats/msgpack/mod.zig");
pub const toml = @import("formats/toml/mod.zig");
pub const csv = @import("formats/csv/mod.zig");
pub const xml = @import("formats/xml/mod.zig");
pub const yaml = @import("formats/yaml/mod.zig");
pub const zon = @import("formats/zon/mod.zig");

pub const serialize = core.serialize;
pub const serializeWith = core.serializeWith;
pub const serializeSchema = core.serializeSchema;
pub const deserialize = core.deserialize;
pub const deserializeWith = core.deserializeWith;
pub const deserializeSchema = core.deserializeSchema;

pub const Kind = core.Kind;
pub const typeKind = core.typeKind;
pub const NamingConvention = core.NamingConvention;
pub const SkipMode = core.SkipMode;
pub const EnumRepr = core.EnumRepr;
pub const UnionTag = core.UnionTag;
pub const Value = core.Value;
pub const Entry = core.Entry;

pub const helpers = struct {
    pub const UnixTimestamp = @import("helpers/timestamp.zig").UnixTimestamp;
    pub const UnixTimestampMs = @import("helpers/timestamp.zig").UnixTimestampMs;
    pub const Base64 = @import("helpers/base64.zig").Base64;
    pub const StreamingDeserializer = @import("helpers/streaming.zig").StreamingDeserializer;
};

test {
    _ = core;
    _ = @import("core/kind.zig");
    _ = @import("core/options.zig");
    _ = @import("core/serialize.zig");
    _ = @import("core/deserialize.zig");
    _ = @import("core/interface.zig");
    _ = @import("core/value.zig");
    _ = @import("helpers/rename.zig");
    _ = @import("helpers/timestamp.zig");
    _ = @import("helpers/base64.zig");
    _ = @import("helpers/streaming.zig");
    _ = compat;
    _ = json;
    _ = @import("formats/json/writer.zig");
    _ = @import("formats/json/scanner.zig");
    _ = @import("formats/json/serializer.zig");
    _ = @import("formats/json/deserializer.zig");
    _ = msgpack;
    _ = @import("formats/msgpack/serializer.zig");
    _ = @import("formats/msgpack/deserializer.zig");
    _ = toml;
    _ = @import("formats/toml/parser.zig");
    _ = @import("formats/toml/serializer.zig");
    _ = @import("formats/toml/deserializer.zig");
    _ = csv;
    _ = @import("formats/csv/scanner.zig");
    _ = @import("formats/csv/serializer.zig");
    _ = @import("formats/csv/deserializer.zig");
    _ = xml;
    _ = @import("formats/xml/writer.zig");
    _ = @import("formats/xml/scanner.zig");
    _ = @import("formats/xml/serializer.zig");
    _ = @import("formats/xml/deserializer.zig");
    _ = yaml;
    _ = @import("formats/yaml/scanner.zig");
    _ = @import("formats/yaml/parser.zig");
    _ = @import("formats/yaml/serializer.zig");
    _ = @import("formats/yaml/deserializer.zig");
    _ = zon;
    _ = @import("formats/zon/serializer.zig");
    _ = @import("formats/zon/deserializer.zig");
}
