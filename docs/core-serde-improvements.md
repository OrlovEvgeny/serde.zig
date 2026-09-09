# Core correctness and performance report

Work on `perf/core-serde-improvements`, September 9, 2026. The starting revision
is `c7f4a1b92e067da37a75ac8ca9d6f82733fb65ff` (`master`). Existing public signatures
remain available. This branch does not add formats or attempt full Rust Serde
compatibility.

## Behavior and reproducible regressions

The executable cases are in `test/core_regressions_test.zig`; they run under the
ordinary testing allocator. Allocation-failure sweeps cover successful parsing,
conversion and serialization, as well as partial construction. Borrowed tests
compare addresses against the original input.

| Trigger | Corrected behavior |
| --- | --- |
| Parse `{}` into a struct with a static string default and another required field | `MissingField`, without freeing the static string |
| Parse `{"text":"first","alias":"second"}` with `alias` mapped to `text` | `DuplicateField`; release the first value and temporary keys |
| Replace a string-valued map entry | Last value wins; replaced value and redundant key are released |
| Parse two allocated strings into a one-element fixed array, or truncate a nested collection | Release the excess/partially constructed values |
| Append garbage to an otherwise valid JSON/MessagePack result | Release the result before returning `TrailingData` |
| Put a borrowed string inside a JSON array, optional or map | Preserve the input view; error cleanup never frees that view |
| Omit a required leaf of recursive `flatten` | `MissingField`; nested rename/skip/default rules and parent defaults apply |
| Serialize recursive `flatten` to MessagePack, CSV or XML | Consistent field count/header/names and nested settings |
| Put internal union tag after payload, or adjacent content before tag | Same value as tag-first input, by replaying the input/tree |
| Adapt an entire internally tagged payload | Inject/filter the tag at the existing object interface, preserving adapter/hook precedence and known MessagePack lengths |
| Fail allocation while trying an untagged variant | Propagate `OutOfMemory` instead of treating it as a type mismatch |
| Put an external adapter inside fields, optional, arrays, slices, tuples, maps, unions or a helper’s wire type | Preserve the adapter in both directions, including layout-sensitive TOML/YAML/XML |
| Skip JSON containing invalid escapes, surrogate pairs or raw UTF-8 | Validate skipped text too; escaped enum/union names decode correctly |
| Convert configured types through `Value.fromAny` / `Value.toType` | Use the common core, including field/union rules and error cleanup |
| Convert TOML/YAML trees to typed output | Release intermediate parser trees after conversion |
| Replace a YAML value that has an anchor, then reference the anchor | Retain an independently owned anchor value; no dangling tree pointer |
| Fail a TOML/MessagePack writer or allocation | Release deferred serializer buffers and partial values |

`test/check_compile_errors.py` verifies that overlapping flattened names and
aliases produce compile errors. NDJSON tests include short reader fills, CRLF,
blank lines, buffer capacity reuse and a final record without newline.

The field and enum behavior follows the applicable parts of the official
[Serde field attributes](https://serde.rs/field-attrs.html) and
[enum representations](https://serde.rs/enum-representations.html). Borrowed
lifetimes follow the same input-outlives-output principle described in
[Serde's lifetime documentation](https://serde.rs/lifetimes.html).

## API and ownership

All nine format modules provide `fromSliceManaged(T, allocator, input)` and
`fromSliceManagedSchema(T, allocator, input, schema)`. The result is a
`serde.Parsed(T)` with `.value` and `.deinit()`. A separately allocated arena
keeps retained allocator contexts valid when the result is moved. Keep one
owner; copying and deinitializing both copies is invalid.

Directional `skip_serializing` and `skip_deserializing` are boolean field maps.
Schema entries override the corresponding in-type settings, including explicit
`false`; `skip.always` still applies in both directions. An omitted/skipped
required field needs a default or an optional type.

Regular derived output can be released with `serde.core.freeAllocated` or
`freeAllocatedSchema`. Defaults and borrowed views are tracked separately from
received fields during error cleanup. Borrowed JSON rejects escaped strings;
use an arena for its allocated container metadata, not `freeAllocated` on the
borrowed result. Managed parsing and caller-owned arenas remain the reliable
choice for arbitrary custom hooks. Arena cleanup only covers allocations made
through that arena, not external resources opened by a hook.

A nonallocating field helper may retain its wire value. An allocating
`with.deserializeAlloc` must return an independent value; the temporary wire
value is released. Custom adapters remain responsible for any private resources
whose ownership cannot be inferred by the core.

## Benchmark method

The same `bench/main.zig`, Zig 0.16.0, `ReleaseFast`, and Apple M4 Pro (24 GiB),
aarch64 macOS 26.6.2 host are used for both revisions. Benchmarks run sequentially without concurrent
builds. Version 3 results contain seven samples' median and min/max, with a
separate allocation-count probe. CPU cases retain an arena or fixed writer
buffer; warm/cold cases include allocation and cleanup with
`std.heap.smp_allocator`. Warm/cold labels specify warmup, not a hardware
cache-flush experiment.

Exploratory page-allocator runs had up to threefold min/max spread in complete
calls on this shared workstation. Version 3 uses the general-purpose SMP
allocator for complete calls, records that choice, and rejects earlier results.
The CPU cases still use a retained arena/fixed buffer. This avoids making
virtual-memory allocation latency the dominant measure of a small record.

The harness releases `fromValue` results, uses the real NDJSON streaming reader,
prepares MessagePack input and maps outside timed operations, and computes
throughput using actual encoded/input lengths. Sample iteration limits were
raised so fast CPU operations are not measured only for fractions of a
millisecond. `std.json` comparisons remain in the raw result files. Incompatible
or malformed baseline metadata is rejected instead of compared.

The baseline needs a higher comptime branch quota to compile the new 64-field
fixture. `bench/prepare_baseline.py` copies the identical harness and adds only
`@setEvalBranchQuota(100_000)` to the baseline struct-deserialization function.
This changes compilation limits, not runtime behavior. CI uses the same script.
The new library's field metadata already raises its evaluation budget.
Harness SHA-256: `605f4bbde00c11ed692e4e6e58973ea90507127c740cb5a66f5cfbafb150c377`.

```sh
# Run from this branch; BASE is a fresh disposable checkout of the starting SHA.
python3 bench/prepare_baseline.py "$BASE"
(cd "$BASE" && mise exec -- zig build bench -Dbench-format=json \
  -Dbench-compare-std-json=true -Dbench-out=bench/core-before.json)
mise exec -- zig build bench -Dbench-format=json \
  -Dbench-compare-std-json=true -Dbench-out=bench/core-after.json
```

Raw measurements: [before](../bench/core-before.json), [after](../bench/core-after.json), and
[correctness checkpoint](../bench/core-correctness.json). The checkpoint is
`c7761a4`, before the field-table/string/NDJSON optimizations; later adapter fixes
do not affect these fixtures. The final measured implementation is `27201be`.
All three files contain the same 59 cases and matching schema/compiler/allocator
metadata. Negative changes mean faster execution.

| Case | Mode | Before ns/op | Checkpoint ns/op | After ns/op | Change |
| --- | --- | ---: | ---: | ---: | ---: |
| `json.wide64.deserialize` | cpu | 2199.9 | 1735.7 | 1422.1 | -35.4% |
| `json.wide.deserialize` | cpu | 464.2 | 464.1 | 479.7 | +3.4% |
| `json.wide_shuffled_alias.deserialize` | cpu | 465.7 | 469.6 | 484.2 | +4.0% |
| `json.nested.deserialize` | cpu | 171.8 | 197.5 | 200.8 | +16.9% |
| `json.array_struct.deserialize` | cpu | 681.6 | 725.1 | 742.4 | +8.9% |
| `json.long_plain.serialize` | cpu | 18663.5 | 16245.9 | 1120.9 | -94.0% |
| `json.long_sparse_escaped.serialize` | cpu | 18311.7 | 17520.1 | 1226.1 | -93.3% |
| `json.long_plain.deserialize` | cpu | 3029.9 | 3006.9 | 835.7 | -72.4% |
| `json.long_escaped.deserialize` | cpu | 10777.5 | 12608.3 | 11917.1 | +10.6% |
| `json.long_sparse_escaped.deserialize` | cpu | 13219.7 | 14338.7 | 1997.9 | -84.9% |
| `json.nested_collections.deserialize` | cpu | 106.8 | 120.4 | 119.2 | +11.6% |
| `ndjson.nested.deserialize` | cpu | 1473.4 | 1456.8 | 766.0 | -48.0% |
| `msgpack.nested.deserialize` | cpu | 68.9 | 63.0 | 62.9 | -8.7% |
| `json.flat_struct.deserialize` | cpu | 80.2 | 81.1 | 82.7 | +3.2% |
| `json.flat_struct.serialize` | cpu | 95.3 | 93.1 | 99.0 | +3.8% |
| `json.flat_struct.deserialize` | warm | 87.5 | 88.1 | 89.1 | +1.9% |
| `json.nested_struct.deserialize` | warm | 184.4 | 215.4 | 221.1 | +19.9% |
| `json.array_struct.roundtrip` | warm | 1548.6 | 1575.7 | 1640.5 | +5.9% |
| `json.borrowed_strings.deserialize` | warm | 55.9 | 69.2 | 65.1 | +16.3% |
| `msgpack.nested_struct.serialize` | warm | 62.9 | 58.3 | 57.8 | -8.2% |
| `csv.large_csv.deserialize` | warm | 755.4 | 735.6 | 734.8 | -2.7% |
| `ndjson.large_ndjson.deserialize` | warm | 1475.8 | 1468.7 | 789.9 | -46.5% |

Remaining key-case regressions above 10% are listed below without exclusions.
The checkpoint helps separate correctness costs from the later optimizations;
it is not a causal decomposition of individual instructions. In these cases the
final version is within 7.5% of, or faster than, that checkpoint.

| Case ID | Change vs starting revision | After min–max ns/op | Change vs checkpoint |
| --- | ---: | ---: | ---: |
| `json.nested.deserialize.serde.cpu` | +16.9% | 199.6–202.1 | +1.7% |
| `json.long_escaped.deserialize.serde.cpu` | +10.6% | 11785.2–12380.5 | -5.5% |
| `json.nested_collections.deserialize.serde.cpu` | +11.6% | 116.4–120.8 | -1.0% |
| `json.nested.serialize.serde.warm` | +11.0% | 190.3–193.9 | +3.1% |
| `json.nested.deserialize.serde.warm` | +19.9% | 219.9–222.6 | +2.7% |
| `json.nested.roundtrip.serde.warm` | +15.5% | 421.4–433.7 | +7.4% |
| `json.nested.deserialize.serde.cold` | +24.0% | 216.9–227.0 | +4.9% |
| `json.nested.roundtrip.serde.cold` | +12.8% | 416.6–430.0 | +4.4% |
| `json.borrowed_strings.deserialize.serde.warm` | +16.3% | 64.1–65.5 | -5.9% |
| `json.borrowed_strings.deserialize.serde.cold` | +16.2% | 64.7–65.7 | -5.9% |

These costs are retained for duplicate-field detection, input-view-aware key
cleanup, propagated reader options, Unicode validation and partial-value
cleanup in the shared core. The nested parse, borrowed-string and dense-escape
controls already show the same regression direction. Short paths also pay a
small extra cost for the shared field/string machinery. This branch prioritizes
the corrected ownership/validation behavior; it does not claim every workload
is faster. Hash lookup below 33 fields and SIMD work on short names were rejected
after measurements. Large-string, 64-field and NDJSON gains remain substantial.

The full-call `std.json` comparison uses the same SMP allocator and lifecycle:

| Flat JSON operation | serde ns/op | std.json ns/op | serde heap requests/op | std.json heap requests/op |
| --- | ---: | ---: | ---: | ---: |
| serialize | 105.5 | 83.3 | 2 | 2 |
| deserialize | 89.1 | 140.5 | 1 | 1 |
| roundtrip | 223.8 | 230.1 | 3 | 3 |

Allocation probes report heap requests and requested bytes, not resident memory
or individual arena suballocations. CPU cases retain storage after warmup; their
zero heap-allocation counts do not mean parsing makes no arena allocation calls.
Min/max and allocation counts for all cases are retained in the raw JSON.

The hash table is used above 32 fields; smaller records use direct comparisons.
Every table lookup verifies the full name, so hash collisions cannot select the
wrong field. Length hints reserve capacity but untrusted binary prefixes are
capped at 64 KiB of eager allocation. JSON scans ordinary text in blocks and
resumes after escapes. NDJSON consumes buffered reader spans and reuses line
capacity between records.

## Verification

| Compiler | Debug | ReleaseSafe | Examples / fuzz builds | Compile-error fixtures |
| --- | --- | --- | --- | --- |
| Zig 0.15.2, SDK 15.4 wrapper | 1069 tests pass | 1069 tests pass | Pass in both modes | Pass |
| Zig 0.16.0 | 1069 tests pass | 1069 tests pass | Pass in both modes | Pass |
| Zig 0.17.0-dev.356+3140b375f | 1069 tests pass | 1069 tests pass | Pass in both modes | Pass |

Formatting is checked with Zig 0.16; Zig master rewrites legacy builtins.
Erlang/OTP 29.0.6 interoperability passes: 22 OTP-to-Zig terms and 8 Zig-to-OTP
terms. Erlang was installed locally for this check. The starting Zig 0.16 suite
passed 1046 tests; the final suite includes 23 additional regression tests.

Reproduce the normal matrix with the installed mise environments:

```sh
mise -E zig16 exec -- zig build test examples fuzz -Doptimize=Debug -j2
mise -E zig16 exec -- zig build test examples fuzz -Doptimize=ReleaseSafe -j2
# Repeat with zig15 and zig17.
mise exec -- python3 test/check_compile_errors.py
mise exec -- zig fmt --check src bench test examples build.zig
mise exec -- zig build interop
```

On this host Zig 0.15.2 cannot link its build runner against SDK 26.5: that SDK's
`libSystem.tbd` lists `arm64e-macos` but not `arm64-macos`. The installed SDK 15.4
has both. `--sysroot` and `MACOSX_DEPLOYMENT_TARGET` alone did not fix the runner.
A temporary `xcrun` wrapper selected SDK 15.4 without changing the machine's SDK
selection or patching the compiler:

```sh
mkdir -p /tmp/serde-sdk15-bin
cat > /tmp/serde-sdk15-bin/xcrun <<'SH'
#!/bin/sh
if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ]; then
    shift 2
    exec /usr/bin/xcrun --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk "$@"
fi
exec /usr/bin/xcrun "$@"
SH
chmod +x /tmp/serde-sdk15-bin/xcrun
env PATH=/tmp/serde-sdk15-bin:$PATH mise -E zig15 exec -- \
  zig build test examples fuzz -Doptimize=Debug -j2
# Repeat with -Doptimize=ReleaseSafe.
```

## Remaining boundaries

- Format root restrictions and writer signatures remain distinct: CSV reads a
  slice of row structs, TOML a struct/table, and XML includes a root element.
- Recursive `flatten` covers structs, not arbitrary flattened maps. Custom hooks
  can define additional semantics; the core does not infer arbitrary resource
  ownership or reverse a helper's nonallocating transformation.
- Internal/adjacent unions replay available input/tree state. This is not a new
  streaming union parser for nonrewindable custom deserializers.
- TOML/YAML parsers remain the existing implementations, with ownership fixes;
  the change does not claim complete TOML/YAML/Rust Serde conformance.
- Fuzz targets were compiled. This report does not claim a sustained fuzzing
  campaign or validation on all hardware/operating systems.
