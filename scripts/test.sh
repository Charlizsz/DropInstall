#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
    "$PROJECT_ROOT/Sources/ImageInput.swift" "$PROJECT_ROOT/Sources/SearchRules.swift" "$PROJECT_ROOT/Sources/Installer.swift" "$PROJECT_ROOT/Sources/AppModel.swift" \
    "$PROJECT_ROOT/tests/ImageInputTests.swift" "$PROJECT_ROOT/tests/NestedImageTests.swift" "$PROJECT_ROOT/tests/InstallerTests.swift" -o "$PROJECT_ROOT/build/installer-tests"
"$PROJECT_ROOT/build/installer-tests"
