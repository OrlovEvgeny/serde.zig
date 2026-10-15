# Apply runtime settings overrides

Model a settings editor that addresses fields by name, then converts the edited values back into a typed worker configuration.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-dynamic-value
```

## Input and output

The defaults and overrides live in `main.zig`. The example changes concurrency
from 4 to 12 and turns off dry-run mode. Stdout contains:

```json
{"service":"invoice-worker","concurrency":12,"dry_run":false}
```

The actual output is pretty-printed; field names and their dynamic tags are
listed on stderr. Change an override to an unknown name, a mismatched type,
or a concurrency outside 1–64 to observe validation failures.

## Patterns to reuse

`toValue` constructs an owning `serde.Value` tree from a typed value. It is not
an arbitrary-JSON parser. The editor permits only unsigned integer and boolean
replacements; strings are read-only, so replacing a field cannot leak an old
string allocation. `Value.deinit` releases the tree.

`fromValue` checks the target Zig types (including integer ranges); application
validation enforces the concurrency limit. The converted configuration uses a
separate arena. Serialize the typed result to obtain ordinary JSON.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
