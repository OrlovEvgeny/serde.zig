#!/usr/bin/env python3
"""Run with `mise exec -- python3 test/check_compile_errors.py`."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
version = subprocess.check_output(["zig", "version"], text=True).strip()
compat = "compat.zig" if version.startswith("0.15.") else "compat_0_16.zig"
for fixture, expected in (("flatten_collision.zig", "Ambiguous serde field name"),
                          ("alias_collision.zig", "Ambiguous serde alias")):
    result = subprocess.run([
        "zig", "build-exe", "-fno-emit-bin", "--dep", "serde",
        f"-Mroot={root / 'test' / 'compile_errors' / fixture}",
        "--dep", "compat", f"-Mserde={root / 'src/root.zig'}",
        f"-Mcompat={root / 'src' / compat}",
    ], capture_output=True, text=True)
    if result.returncode == 0 or expected not in result.stderr:
        raise SystemExit(f"{fixture}: wrong result\n{result.stderr}")
    print(f"{fixture}: rejected as expected ({version})")
