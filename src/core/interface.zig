/// Comptime verification of Serializer and Deserializer interfaces.
/// Historical declaration-only serializer check; use assertSerializer for strict probes.
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

/// Historical declaration-only deserializer check; use assertDeserializer for strict probes.
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
    if (@typeInfo(@TypeOf(@field(T, name))) != .@"fn")
        @compileError(@typeName(T) ++ "." ++ name ++ ": expected a function");
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
    const s: *S = undefined;
    checkResult(S, "serializeBool", @TypeOf(s.serializeBool(true)), void);
    checkResult(S, "serializeInt", @TypeOf(s.serializeInt(@as(i32, 1))), void);
    checkResult(S, "serializeFloat", @TypeOf(s.serializeFloat(@as(f64, 1))), void);
    checkResult(S, "serializeString", @TypeOf(s.serializeString("")), void);
    checkResult(S, "serializeNull", @TypeOf(s.serializeNull()), void);
    checkResult(S, "serializeVoid", @TypeOf(s.serializeVoid()), void);
    checkResult(A, "end", @TypeOf(@as(*A, undefined).end()), void);
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
    const m: *M = undefined;
    checkResult(M, "serializeField", @TypeOf(m.serializeField("key", true)), void);
    checkResult(M, "serializeEntry", @TypeOf(m.serializeEntry(@as([]const u8, "key"), true)), void);
    checkResult(M, "end", @TypeOf(m.end()), void);
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
        requireError(A);
        require(A, "nextElement");
        const d: *D = undefined;
        const allocator: @import("std").mem.Allocator = undefined;
        checkResult(D, "deserializeBool", @TypeOf(d.deserializeBool()), bool);
        checkResult(D, "deserializeInt", @TypeOf(d.deserializeInt(i32)), i32);
        checkResult(D, "deserializeFloat", @TypeOf(d.deserializeFloat(f64)), f64);
        checkResult(D, "deserializeString", @TypeOf(d.deserializeString(allocator)), []const u8);
        checkResult(D, "deserializeVoid", @TypeOf(d.deserializeVoid()), void);
        checkResult(D, "deserializeOptional", @TypeOf(d.deserializeOptional(i32, allocator)), ?i32);
        const E = enum { item };
        const U = union(enum) { item: i32 };
        checkResult(D, "deserializeEnum", @TypeOf(d.deserializeEnum(E)), E);
        checkResult(D, "deserializeUnion", @TypeOf(d.deserializeUnion(U, allocator)), U);
        checkResult(M, "nextKey", @TypeOf(@as(*M, undefined).nextKey(allocator)), ?[]const u8);
        checkResult(M, "nextValue", @TypeOf(@as(*M, undefined).nextValue(i32, allocator)), i32);
        checkResult(M, "skipValue", @TypeOf(@as(*M, undefined).skipValue()), void);
        checkResult(A, "nextElement", @TypeOf(@as(*A, undefined).nextElement(i32, allocator)), ?i32);
        if (@TypeOf(d.raiseError(error.MissingField)) != D.Error or @TypeOf(@as(*M, undefined).raiseError(error.MissingField)) != M.Error)
            @compileError("serde raiseError must return the backend Error set");
        if (@hasDecl(D, "serde_protocol")) {
            const P = D.serde_protocol;
            if (@hasDecl(P, "checkpoint") != @hasDecl(P, "restore"))
                @compileError(@typeName(D) ++ ": declare both serde_protocol.checkpoint and serde_protocol.restore");
        }
    }
}

fn checkResult(comptime Owner: type, comptime method: []const u8, comptime Result: type, comptime Expected: type) void {
    if (@typeInfo(Result) != .error_union or @typeInfo(Result).error_union.payload != Expected)
        @compileError(@typeName(Owner) ++ "." ++ method ++ ": expected an error union with payload " ++ @typeName(Expected));
}
