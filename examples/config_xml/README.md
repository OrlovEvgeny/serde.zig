# Bridge legacy XML settings to JSON

Read an XML application configuration and produce a public JSON status view while preserving an XML export path.

## Run

From the repository root, with a supported Zig toolchain (0.15.2 or newer;
see the [compatibility table](../../README.md#installation)):

```sh
zig build example-config-xml
```

## Input and output

[config.xml](config.xml) is read at runtime with a 64 KiB limit. It uses `id` and
`version` attributes, a nested database element, and a list of feature elements.
The service name contains `&amp;`, decoded to `Orders & Billing` in memory.

Stdout contains the JSON status view: ID, version, name, and features. Database
settings are excluded by an external schema. Stderr shows normalized XML,
including database settings, with the original attribute mapping and escaped
ampersand. The source file is never overwritten.

## Patterns to reuse

`xml_root` and `xml_attribute` describe the legacy wire shape. A managed result
owns the decoded strings and list. Before export, the application accepts only
version `2.1`, nonempty identifiers and database settings, a nonzero database
port, and the supported `logging`, `metrics`, and `tracing` feature names.

The same typed value feeds JSON and XML serializers. The XML output preserves
data and mappings, not the source document's whitespace or comments. Edit the
fixture to try another entity-escaped name or an unsupported feature.

See [main.zig](main.zig) for the complete implementation and the
[examples index](../README.md) for related scenarios.
