# Load and validate service settings

Read a service configuration, apply defaults, validate startup settings, and export the effective TOML.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-config-toml
```

## Input and output

Edit [service.toml](service.toml) and rerun. The runtime file read is limited to
64 KiB. The fixture selects port 9090, 8 workers, and a pool of 25 connections.
It omits the server host, database port, and timeout, which become `127.0.0.1`,
5432, and 30 seconds.

The effective configuration goes to stdout, including defaults. A startup summary
goes to stderr. No file is created or overwritten, and no database connection is
opened. Save the result explicitly if needed:

```sh
zig build example-config-toml > /tmp/effective-service.toml
```

## Patterns to reuse

Nested structs map to TOML tables. `fromSliceManaged` owns parsed strings and
releases them with one `deinit`. Required fields have no Zig defaults; optional
settings do. Validation rejects empty names/hosts, zero ports, workers, pool
sizes, and timeouts before the configuration is used. Errors propagate as a
nonzero exit status. `toSlice` output is a separate allocation.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
