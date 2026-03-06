pub const core = @import("core/mod.zig");
pub const json = @import("formats/json/mod.zig");

pub const serialize = core.serialize;
pub const deserialize = core.deserialize;

pub const Kind = core.Kind;
pub const typeKind = core.typeKind;
pub const NamingConvention = core.NamingConvention;
pub const SkipMode = core.SkipMode;

test {
    // Pull in all modules for testing.
    _ = core;
    _ = @import("core/kind.zig");
    _ = @import("core/options.zig");
    _ = @import("core/serialize.zig");
    _ = @import("core/deserialize.zig");
    _ = @import("core/interface.zig");
    _ = @import("helpers/rename.zig");
    _ = json;
    _ = @import("formats/json/writer.zig");
    _ = @import("formats/json/scanner.zig");
    _ = @import("formats/json/serializer.zig");
    _ = @import("formats/json/deserializer.zig");
}
