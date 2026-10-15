# Export one configuration to several formats

Use TOML as the source of a service configuration, export it for different consumers, and verify that each full export preserves its data.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-multi-format
```

## Input and output

Edit [service.toml](service.toml) and rerun. The file is read at runtime with a
64 KiB limit. The output on stdout has labeled JSON, TOML, YAML, XML, ZON, and
TOON sections, followed by a CSV inventory. It is a demonstration report, not a
single machine-readable document.

Five full exports use the kebab-case schema. ZON uses the original snake_case
Zig field names because the current backend requires identifier-compatible keys.
Each is parsed back into the same type, then compared with the source through a canonical JSON encoding.
A mismatch fails the program; stderr confirms six successful roundtrips.

CSV deliberately selects flat inventory columns:

```csv
service-name,port-number,region,tier
orders-api,8080,eu-west-1,staging
```

This projection omits retries, enabled state, and description. It is not a
lossless backup of the configuration.

## Patterns to reuse

A managed TOML result owns the source data. The reusable `exportConfig` function
pairs `toSliceSchema` with `fromSliceManagedSchema` and checks all typed fields.
Validation requires nonempty service/region/tier values, a nonzero port, and at
most ten retries. This model uses a common subset supported by the six text
formats; it does not imply all formats support every Zig type. See the
[capability matrix](../../docs/capabilities.md).

For MessagePack and ETF transport, use the
[binary interchange example](../binary_interchange/README.md).

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
