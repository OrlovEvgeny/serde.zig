# Type and adapter author guide

Start with the independently built [type author package](../test/packages/type_author/main.zig).
Run `zig build test` in `test/packages/type_author`, or run
`python3 test/check_package.py` to verify the distributed package as well.
It imports only `serde` and tests nested external adapters and temporary strings.

A type you control can implement:

```zig
pub fn zerdeSerialize(value: MyType, s: anytype) @TypeOf(s.*).Error!void {
    return s.serializeInt(value.raw);
}
pub fn zerdeDeserialize(comptime _: type, allocator: std.mem.Allocator,
    d: anytype) @TypeOf(d.*).Error!MyType {
    _ = allocator;
    return .{ .raw = try d.deserializeInt(u64) };
}
```

For a type owned by another library, put the corresponding methods in an adapter
as `serialize(value, s)` and `deserialize(comptime T, allocator, d)`. Pass
`.{.{ MyType, MyAdapter }}` to `serde.serializeWith` / `deserializeWith`, or the
format's convenience functions where provided. Hooks on the type take priority
over external adapters. A schema changes naming, defaults and layout; an adapter
changes the value's representation. The [schema example](../examples/schema_override/main.zig)
shows external naming policies.

Keep hooks format-independent by using scalar/container methods and generic core
recursion. Reading a concrete parser's fields breaks other formats and diagnostic
wrappers. Honor the allocator, release partial results on errors, and use
`serde.core.releaseString(d, allocator, text)` for temporary strings. If the hook
returns allocated storage, it transfers ownership to the result. Managed parsing
is the recommended application-facing lifetime.

## Token tests

`serde.testing` provides `Token`, `TokenSerializer`, `TokenDeserializer`,
`expectSerialize(value, tokens)`, and `expectDeserialize(T, value, tokens)`.
For example:

```zig
try serde.testing.expectSerialize(@as(u16, 7), &.{
    .{ .uint = .{ .bits = 16, .value = 7 } },
});
try serde.testing.expectDeserialize(u16, 7, &.{
    .{ .uint = .{ .bits = 16, .value = 7 } },
});
```

Numbers preserve signedness and width: integer payloads hold up to 128 bits and
float payloads use f128. Supply typed values; width is part of the assertion.
Tokens distinguish null from void. Optional values emit null or their payload.
Arrays/tuples and objects have explicit begin/end events. Field and variant names
are string events. Maps can emit nonstring keys, but the current generic map
reader accepts string keys. No `Value` conversion is involved.

For schemas and external adapters, use a caller-owned `[]Token` buffer:
`var s = TokenSerializer.init(allocator, &buffer)`, then `serde.serializeSchema` or
`serializeWith`. Defer `s.deinit()` and inspect `s.tokens()` before that cleanup.
The serializer copies string payloads, including temporary buffers emitted by
custom hooks. Do not replace its owned string entries before deinitializing it.
The caller owns the token buffer; string copies use the supplied allocator.
Insufficient token capacity or allocation failure returns `OutOfMemory`. `TokenDeserializer.init(events)` copies
returned strings using the provided allocator, and `finish()` rejects unused
events. `expectDeserialize` uses an arena and releases it after comparison.

See [token integration tests](../test/tokens_test.zig) for aliases, flatten,
nullable fields, event ordering, union payloads, and nested adapters. Passing token
tests proves a type's mapping, not a format's specification compliance.
