#!/bin/bash
# Sourced by build/test scripts. No changes to the installed toolchain.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/build"
SWIFT_FLAGS=(-swift-version 6)
TOOLCHAIN_ROOT="$(cd "$(dirname "$(xcrun --find swiftc)")/.." && pwd)"
OLD_MAP="$TOOLCHAIN_ROOT/include/swift/module.modulemap"
NEW_MAP="$TOOLCHAIN_ROOT/include/swift/bridging.modulemap"
# Some CLT upgrades leave two equivalent SwiftBridging module maps behind.
# Hide only the stale duplicate in a compiler-local virtual filesystem overlay.
if [[ -f "$OLD_MAP" && -f "$NEW_MAP" ]] && \
   /usr/bin/grep -q 'module SwiftBridging' "$OLD_MAP" && \
   /usr/bin/grep -q 'module SwiftBridging' "$NEW_MAP"; then
    : > "$PROJECT_ROOT/build/empty.modulemap"
    /usr/bin/python3 - "$OLD_MAP" "$PROJECT_ROOT/build" <<'PY'
import json, os, sys, tempfile
old, build = sys.argv[1:]
data = {"version": 0, "roots": [{"type": "file", "name": old,
        "external-contents": os.path.join(build, "empty.modulemap")}]}
with tempfile.NamedTemporaryFile(mode="w", dir=build, delete=False) as out:
    json.dump(data, out)
os.replace(out.name, os.path.join(build, "toolchain-overlay.json"))
PY
    SWIFT_FLAGS+=(-vfsoverlay "$PROJECT_ROOT/build/toolchain-overlay.json")
fi
