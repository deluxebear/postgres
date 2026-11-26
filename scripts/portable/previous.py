#!/usr/bin/env python3
"""Fetch a checksummed predecessor from this repository's published assets."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request


bundle = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
manifest = json.loads((bundle / "portable-release.json").read_text())
previous = manifest.get("predecessor")
if previous is None:
    print("First custom portable release: no predecessor binary exists.")
    sys.exit(0)
platform = json.loads((bundle / "extensions.json").read_text())["platform"]
suffix = f"-{platform}.tar.gz"
assets = [a for a in previous["assets"] if a["name"].endswith(suffix)]
if len(assets) != 1:
    raise ValueError(f"Missing unique predecessor archive for {platform}")
archive = assets[0]
checksums = [a for a in previous["assets"] if a["name"] == archive["name"] + ".sha256"]
if len(checksums) != 1:
    raise ValueError("Missing predecessor checksum")
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for asset, filename in ((archive, "previous.tar.gz"), (checksums[0], "checksum")):
        # These are public release assets, never forward an API bearer token.
        urllib.request.urlretrieve(asset["url"], root / filename)
    fields = (root / "checksum").read_text().split()
    if len(fields) != 2 or fields[1].lstrip("*") != archive["name"] or not re.fullmatch("[0-9a-f]{64}", fields[0]):
        raise ValueError("Invalid predecessor checksum file")
    with (root / "previous.tar.gz").open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != fields[0]:
            raise ValueError("Predecessor archive checksum mismatch")
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["tar", "-xzf", str(root / "previous.tar.gz"), "-C", str(output)], check=True)
print(f"Downloaded verified predecessor {previous['tag']} ({platform}).")
