#!/usr/bin/env python3
"""Build consumers in a temporary tree containing only build.zig.zon .paths."""
import pathlib
import re
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
manifest = (root / "build.zig.zon").read_text()
match = re.search(r"\.paths\s*=\s*\.\{([^}]+)\}", manifest)
if not match:
    raise SystemExit("Could not read the package allowlist")
paths = re.findall(r'"([^"\n]+)"', match.group(1))
with tempfile.TemporaryDirectory(prefix="serde-package-") as temporary:
    package = pathlib.Path(temporary) / "serde"
    package.mkdir()
    for path in paths:
        source, target = root / path, package / path
        if source.is_dir():
            shutil.copytree(source, target, ignore=shutil.ignore_patterns(".zig-cache", "zig-out", "__pycache__"))
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    for required in ("README.md", "LICENSE", "docs/application-author.md", "docs/type-author.md", "docs/format-author.md"):
        if not (package / required).is_file():
            raise SystemExit(f"Package is missing {required}")
    for consumer in ("type_author", "format_author"):
        subprocess.run(["zig", "build", "test"], cwd=package / "test/packages" / consumer, check=True)
        print(f"{consumer}: passed using only packaged public API", flush=True)
