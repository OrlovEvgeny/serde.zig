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

/// Whether S implements the optional length-aware container API.
///
/// `beginArray` / `beginStruct` let a serializer discover the element count
/// only at `end()`, which forces length-prefixed formats such as MessagePack
/// to buffer the payload. A serializer may additionally declare:
///
///     fn beginArrayLen(self: *S, len: usize) Error!ArrayContainer
///     fn beginStructLen(self: *S, len: usize) Error!StructContainer
///
/// which the core calls whenever the count is known up front, letting the
/// serializer emit the header first and stream the payload.
///
/// Contract: the caller must emit **exactly** `len` elements or fields into
/// the returned container before calling `end()`. Writing a different number
/// silently produces a malformed document, so serializers are encouraged to
/// assert the count under `std.debug.runtime_safety`.
///
/// Both declarations must be present or absent together.
pub fn hasKnownLengthContainers(comptime S: type) bool {
    const has_array = @hasDecl(S, "beginArrayLen");
    const has_struct = @hasDecl(S, "beginStructLen");
    if (has_array != has_struct)
        @compileError(@typeName(S) ++ " must declare both beginArrayLen and beginStructLen, or neither");
    return has_array;
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

fn require(comptime T: type, comptime name: []const u8) void {
    if (@typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union")
        @compileError(@typeName(T) ++ ": expected a serde backend/container type");
    if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ ": missing serde method " ++ name);
    if (!@typeInfo(@TypeOf(@field(T, name))).@"fn".is_generic and
        @typeInfo(@TypeOf(@field(T, name))).@"fn".return_type == null)
        @compileError(@typeName(T) ++ "." ++ name ++ ": expected a return type");
}
fn requireError(comptime T: type) void {
    if (!@hasDecl(T, "Error")) @compileError(@typeName(T) ++ ": missing serde Error declaration");
    if (@typeInfo(T.Error) != .error_set) @compileError(@typeName(T) ++ ".Error must be an error set");
}
fn payload(comptime T: type) type {
    if (@typeInfo(T) != .error_union) @compileError("serde methods must return an error union");
    return @import("protocol.zig").Backend(@typeInfo(T).error_union.payload);
}

/// Opt-in structural validation. This does not prove format semantics or supported types.
pub fn assertSerializer(comptime S: type) void {
    comptime checkSerializer(S, .{});
}
fn checkSerializer(comptime S: type, comptime visited: anytype) void {
    inline for (visited) |V| if (S == V) return;
    requireError(S);
    inline for (.{ "serializeBool", "serializeInt", "serializeFloat", "serializeString", "serializeNull", "serializeVoid", "beginArray", "beginStruct" }) |name| require(S, name);
    const A = payload(@TypeOf(@as(*S, undefined).beginArray()));
    require(A, "end");
    checkSerializer(A, visited ++ .{S});
    checkStructContainer(payload(@TypeOf(@as(*S, undefined).beginStruct())));
    if (hasKnownLengthContainers(S)) {
        const AL = payload(@TypeOf(@as(*S, undefined).beginArrayLen(0)));
        require(AL, "end");
        checkSerializer(AL, visited ++ .{S});
        checkStructContainer(payload(@TypeOf(@as(*S, undefined).beginStructLen(0))));
    }
}
fn checkStructContainer(comptime M: type) void {
    requireError(M);
    inline for (.{ "serializeField", "serializeEntry", "end" }) |name| require(M, name);
}

/// Validate the full core deserializer contract. Restricted backends can return
/// Error!void for unsupported container profiles; these are not full backends.
pub fn assertDeserializer(comptime D: type) void {
    comptime {
        requireError(D);
        for (.{ "deserializeBool", "deserializeInt", "deserializeFloat", "deserializeString", "deserializeVoid", "deserializeOptional", "deserializeStruct", "deserializeSeqAccess", "deserializeEnum", "deserializeUnion", "raiseError" }) |name| require(D, name);
        const M = payload(@TypeOf(@as(*D, undefined).deserializeStruct(struct {})));
        requireError(M);
        for (.{ "nextKey", "nextValue", "skipValue", "raiseError" }) |name| require(M, name);
        const A = payload(@TypeOf(@as(*D, undefined).deserializeSeqAccess()));
        require(A, "nextElement");
        if (@hasDecl(D, "serde_protocol")) {
            const P = D.serde_protocol;
            if (@hasDecl(P, "checkpoint") != @hasDecl(P, "restore"))
                @compileError(@typeName(D) ++ ": declare both serde_protocol.checkpoint and serde_protocol.restore");
        }
    }
}
