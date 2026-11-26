#!/usr/bin/env python3
"""Record default SQL extension versions from the actual portable artifact."""

import json
from pathlib import Path
import re
import subprocess
import sys


def inventory(bundle, platform):
    bundle = Path(bundle).resolve()
    release = json.loads((bundle / "portable-release.json").read_text())
    extensions = {}
    for control in sorted((bundle / "share/postgresql/extension").glob("*.control")):
        match = re.search(r"^\s*default_version\s*=\s*'([^']+)'", control.read_text(), re.M)
        if match:
            extensions[control.stem] = match[1]
    for name, extension in release["extensions"].items():
        if extensions.get(name) != extension["sql_version"]:
            raise ValueError(f"{name}: actual control version differs from resolved stable release")
    version = subprocess.check_output([str(bundle / "bin/postgres"), "--version"], text=True).strip()
    result = {"platform": platform, "postgresql": version, "extensions": extensions, "release": release}
    (bundle / "extensions.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    inventory(sys.argv[1], sys.argv[2])
