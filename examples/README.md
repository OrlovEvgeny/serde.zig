# Practical serde.zig examples

Each directory contains a complete program, its input fixtures where needed,
and a README explaining the scenario, output, ownership, and limitations.
Start with `basic_json` for a small application or `managed_json` for parsing
and error diagnostics.

## Choose a scenario

| Example | Practical task | Main APIs and concepts |
| --- | --- | --- |
| [basic_json](basic_json/README.md) | Calculate an order receipt from JSON | Nested data, managed parsing, integer money, validation |
| [managed_json](managed_json/README.md) | Validate independent email jobs | Managed lifetimes, diagnostic paths, recovery after bad input |
| [http_api](http_api/README.md) | Handle order webhook payloads | Tagged unions, camelCase, flattening, skipped fields |
| [custom_types](custom_types/README.md) | Verify an artifact manifest | Custom hooks, large IDs as strings, SHA-256 as hex |
| [config_toml](config_toml/README.md) | Load and export effective service settings | Nested tables, defaults, startup validation |
| [config_yaml](config_yaml/README.md) | Inspect a deployment manifest | Maps, dependency references, sorted public inventory |
| [config_xml](config_xml/README.md) | Bridge legacy XML settings to JSON | Attributes, entities, lists, schema-based projection |
| [schema_override](schema_override/README.md) | Publish a redacted configuration view | External schemas for dependency-owned types |
| [csv_pipeline](csv_pipeline/README.md) | Aggregate department payroll | Row decoding, per-row cleanup, exact totals, CSV output |
| [streaming_ndjson](streaming_ndjson/README.md) | Extract alerts from a log file | File streaming, malformed records, per-record cleanup |
| [binary_interchange](binary_interchange/README.md) | Exchange telemetry messages | MessagePack, ETF, versions, units, roundtrip verification |
| [multi_format](multi_format/README.md) | Export configuration for different consumers | Six text formats, format-specific schemas, flat CSV projection |
| [dynamic_value](dynamic_value/README.md) | Apply runtime settings overrides | Owning `Value` trees, type checks, conversion back to structs |

## Run

Use a supported Zig toolchain from the repository root. The repository defaults
to Zig 0.17.0; see the [compatibility table](../README.md#installation).

```sh
zig build example-basic-json
zig build example-streaming-ndjson
```

Every directory name maps to an `example-` build target with underscores replaced
by hyphens. Build all programs without running them:

```sh
zig build examples
```

Run the installed programs from the repository root so runtime fixture paths
resolve. For example:

```sh
./zig-out/bin/example-csv-pipeline > /tmp/department-payroll.csv
```

On a POSIX shell, run all installed examples:

```sh
for example in zig-out/bin/example-*; do
    "$example" || exit 1
done
```

On Windows, executables have the `.exe` suffix; the `zig build example-*`
commands work the same way.

## Adapt a program

File-based examples read the fixture path shown in their README; they do not
accept command-line arguments. Edit a fixture and rerun. `managed_json` embeds
its fixtures, so use its build target after editing to recompile them. Other
in-memory inputs are near `main` and can be changed there.

Programs do not overwrite fixtures or create application files. Most put their
JSON, CSV, TOML, or NDJSON result on stdout and diagnostics on stderr, allowing
redirection. `managed_json` is diagnostics-only; `multi_format` emits a labeled
report containing several documents. Example data is synthetic and requires no
running server, database, broker, or network connection.

Each README explains which input errors stop execution and which are expected
rejections. Ownership examples use `Parsed(T).deinit`, explicit output cleanup,
or per-record `freeAllocated` calls. See the
[application author guide](../docs/application-author.md) for the API contract
and the [capability matrix](../docs/capabilities.md) for format limitations.
