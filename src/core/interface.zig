/// Comptime verification of Serializer and Deserializer interfaces.
/// Whether S implements the full Serializer interface.
pub fn isSerializer(comptime S: type) bool {
    return @hasDecl(S, "serializeBool") and
        @hasDecl(S, "serializeInt") and
        @hasDecl(S, "serializeFloat") and
        @hasDecl(S, "serializeString") and
        @hasDecl(S, "serializeNull") and
        @hasDecl(S, "serializeVoid") and
        @hasDecl(S, "beginArray") and
        @hasDecl(S, "beginStruct");
}

/// Whether D implements the full Deserializer interface.
pub fn isDeserializer(comptime D: type) bool {
    return @hasDecl(D, "deserializeBool") and
        @hasDecl(D, "deserializeInt") and
        @hasDecl(D, "deserializeFloat") and
        @hasDecl(D, "deserializeString") and
        @hasDecl(D, "deserializeOptional") and
        @hasDecl(D, "deserializeStruct") and
        @hasDecl(D, "deserializeSeq") and
        @hasDecl(D, "deserializeEnum");
}
