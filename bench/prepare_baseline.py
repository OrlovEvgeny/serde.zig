#!/usr/bin/env python3
"""Install the current harness in a disposable baseline checkout."""
import pathlib
import shutil
import sys

checkout = pathlib.Path(sys.argv[1]).resolve()
shutil.copyfile(pathlib.Path(__file__).with_name("main.zig"), checkout / "bench/main.zig")
# Older reflection code exceeds Zig's default evaluation budget on 64 fields.
# This changes only the compiler's budget, never the measured runtime algorithm.
source = checkout / "src/core/deserialize.zig"
text = source.read_text()
name = "fn deserializeStructFieldsSchema("
if name in text:
    start = text.index("{\n", text.index(name)) + 2
    directive = "    @setEvalBranchQuota(100_000);\n"
    if not text[start:].startswith(directive):
        source.write_text(text[:start] + directive + text[start:])
        print("baseline: raised comptime budget for the 64-field fixture")
