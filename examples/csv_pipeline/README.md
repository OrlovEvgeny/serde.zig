# Build a department payroll report

Import employee rows and emit a compact CSV report with headcount, remote headcount, and annual payroll per department.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-csv-pipeline
```

## Input and output

Edit [employees.csv](employees.csv) to change the input. It is read at runtime
with a 1 MiB limit. The fixture includes a quoted name containing a comma and
empty optional manager fields. All salary amounts are EUR cents.

Stdout is a CSV document suitable for a spreadsheet or another import:

```csv
department,headcount,remote_count,annual_payroll_cents
Engineering,3,3,36500000
Marketing,2,0,18400050
```

```sh
zig build example-csv-pipeline > /tmp/department-payroll.csv
```

A five-employee import summary goes to stderr. No employee names or manager
details are included in the report. Empty imports, zero employee IDs, empty
names/departments, malformed rows, and arithmetic overflow fail the program.

## Patterns to reuse

The CSV streaming deserializer decodes one row at a time from an already loaded
input slice; it does not stream the file from disk. Each row is released with
`freeAllocated` after its totals are accumulated. Department keys are copied
into the aggregate map so they survive row cleanup. Report rows borrow those
keys and are sorted by department for stable output.

Integer cents avoid floating-point payroll totals. This is an aggregate report,
not a payroll engine: it assumes one row per employee and does not deduplicate
IDs, calculate deductions, or validate manager relationships.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
