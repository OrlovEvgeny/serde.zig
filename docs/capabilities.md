# Capability matrix

This describes the implementation in the v1.2 tree, not a claim of complete
compliance with every format specification. Test suites exercise supported
mappings, errors and regressions. They do not certify entire specifications.

| Format | Typical root types | Number representation / notable limits | Borrowed strings | Parsing strategy |
| --- | --- | --- | --- | --- |
| JSON | scalar, struct/map, sequence, union | typed decimal numbers; non-finite output becomes null | `fromSliceBorrowed`, unescaped strings only | slice scanner |
| MessagePack | scalar, struct/map, sequence, union | integer wire range i64/u64; f32/f64 (wider input narrows) | no borrowing helper | byte cursor |
| ETF | scalar, struct/map, sequence, union; raw `Term` API separately | integer/bignum; floats become f64 | no borrowing helper | term decoding and typed visitor |
| TOML | root table/struct | parsed integers i64, floats f64; root scalar/sequence unsupported | no | allocated table tree |
| YAML | scalar, mapping, sequence, union | parsed integers i64, floats f64 | no | allocated YAML value tree |
| XML | types represented by root elements | textual typed numbers; XML has no intrinsic numeric types | `fromSliceBorrowed`; entity decoding restricts borrowing | XML scanner |
| ZON | scalar, struct, sequence, enum | textual typed numbers; default external union reader unsupported | `fromSliceBorrowed`, unescaped strings only | slice parser |
| TOON | scalar, object, array; typed mappings through conversion | dynamic i64/u64/f64 and number strings; do not assume wide numeric fidelity | no | allocated tree / conversion |
| CSV | rows: slices of structs | textual cells; not arbitrary nested values | no | buffered CSV rows |

Generic map deserialization reads string keys, even for formats that can represent
other key types. The serializer's `serializeEntry` can accept other key types if
the format supports them; that does not imply a matching generic read path.
`Value` also has string keys and i64/u64/f64 numeric storage. Use the typed APIs
and test the precise number range you need. In particular, out-of-range wide
integers passed to MessagePack serialization can fail a checked narrowing cast;
its wire format does not preserve all i128/u128 values.

The listed borrowing helpers retain the input lifetime. They do not make all
container allocations disappear. Escapes/entities can make a string unsuitable
for borrowing. See the [ownership guide](application-author.md).

All current `fromReader` convenience paths read the input into memory before
parsing (typically with a 10 MiB limit). They are not incremental readers.
NDJSON has a separate line-oriented helper; this does not make replaying unions
possible on every stream.

## Schema and adapter access

All formats expose slice schema helpers and managed/schema parsing. JSON, ETF,
and TOON also expose `fromSliceWithMap` / `toSliceWithMap` adapter conveniences.
The public core `serializeWith`, `deserializeWith`, `serializeSchema`, and
`deserializeSchema` work with low-level backends; format layout and root limits
still apply. Writer signatures differ: some backends need an allocator and
format-specific framing or options. See the corresponding compiled examples.

The full deserializer structural probes cover JSON, MessagePack, YAML, XML and
ETF; ZON, TOML and CSV require supported-profile tests because some root or union
operations are unavailable. TOON exposes conversion helpers rather than the same
low-level `Deserializer` type. Token tests validate a mapping independently from
these format differences.

## Evidence and remaining work

- Unit, regression, roundtrip, malformed-input and allocation-failure tests run
  through `zig build test`. Debug and ReleaseSafe are both CI requirements.
- `test/check_compile_errors.py` verifies diagnostic text for invalid schemas and
  missing extension methods/replay. `test/check_package.py` builds both independent
  consumers from the `.paths` allowlist.
- JSON diagnostics are compared with ordinary parsing across a corpus and every
  input prefix, including errors, unions, schemas, Unicode and partial cleanup.
- ETF has an executable bidirectional Erlang/OTP 29 corpus (`zig build interop`).
  This covers that corpus, not every possible ETF term or distribution exchange.
- Nine fuzz harnesses are compiled by CI. Long-running fuzz execution and complete
  conformance suites remain future work. Passing compilation is not a fuzz result.
- Linux/macOS/Windows and Zig 0.15.2/0.16.0/master are configured in CI. A local
  run proves only the tested host and installed compiler revisions. See
  [the release verification record](v1.2.0-verification.md).
