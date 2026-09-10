const serde = @import("serde");
const Base = serde.json.Deserializer;
const D = struct {
    pub const Error = Base.Error;
    pub const deserializeBool = Base.deserializeBool;
    pub const deserializeInt = Base.deserializeInt;
    pub const deserializeFloat = Base.deserializeFloat;
    pub const deserializeString = Base.deserializeString;
    pub const deserializeVoid = Base.deserializeVoid;
    pub const deserializeOptional = Base.deserializeOptional;
    pub const deserializeStruct = Base.deserializeStruct;
    pub const deserializeEnum = Base.deserializeEnum;
    pub const deserializeUnion = Base.deserializeUnion;
    pub const raiseError = Base.raiseError;
};
pub fn main() void {
    comptime serde.core.assertDeserializer(D);
}
