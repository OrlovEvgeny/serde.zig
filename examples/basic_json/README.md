# Calculate an order receipt

Read an order from JSON, validate its line items, and emit a receipt that a checkout service could return.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-basic-json
```

## Input and output

Edit [order.json](order.json) to change quantities or prices. The program reads
this file at runtime, with a 64 KiB limit. Only EUR is accepted in this example.
An empty order, empty SKU, or zero quantity fails with a nonzero exit status.

The fixture produces `item_count: 3`, `total_cents: 2995`, and `note: null`.
Prices are integer cents; multiplication widens to `u64` and accumulation checks
for overflow. Tax, discounts, and shipping are outside this calculation.

Stdout contains only the JSON receipt, so it can be redirected:

```sh
zig build example-basic-json > /tmp/receipt.json
```

## Patterns to reuse

- Nested structs and slices describe the input contract.
- `fromSliceManaged` owns all parsed allocations; `deinit` releases them together.
- The receipt borrows parsed strings until serialization finishes.
- `toSliceWith` supports pretty JSON; its output is freed separately.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
