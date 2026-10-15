# Inspect a deployment manifest

Load a Compose-style YAML manifest, check dependency references, and export a service inventory without environment values.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-config-yaml
```

## Input and output

[docker.yaml](docker.yaml) is read at runtime with a 256 KiB limit. It describes
`web`, `api`, and `db`, with quoted port mappings, optional environment maps,
and dependency lists. Images are illustrative; the example does not pull them
or start containers.

Stdout contains a JSON array sorted by service name: `api`, `db`, `web`.
Each row includes its name, image, published ports, and dependency count.
The database has no published ports. Environment values are deliberately absent
from the inventory because deployment settings can contain credentials.

Change a dependency to a nonexistent service to see `UnknownDependency` and a
message naming the referring service. Empty deployments, empty service names
or images, and direct self-dependencies also fail.

## Patterns to reuse

`StringHashMap(Service)` handles arbitrary service names. Nested maps, slices,
and defaults are owned by one managed result. Inventory rows borrow strings
from that result until serialization completes. Sorting removes hash iteration
order from the output.

This is a small application schema, not a full Compose validator. It does not
resolve variables, validate image/port syntax, detect indirect dependency
cycles, or calculate startup order.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
