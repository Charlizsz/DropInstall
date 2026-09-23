#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/DropInstall-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
APP="$PACKAGE_STAGE/DropInstall.app"
DELIVERABLE="$PROJECT_ROOT/dist/DropInstall.app"
mkdir -p "$PROJECT_ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
    echo "Building ${ARCH}..."
    xcrun swiftc "${SWIFT_FLAGS[@]}" -target "$ARCH-apple-macosx14.0" -O -parse-as-library \
        "$PROJECT_ROOT"/Sources/*.swift -o "$PROJECT_ROOT/build/DropInstall-$ARCH"
done
xcrun lipo -create "$PROJECT_ROOT/build/DropInstall-arm64" "$PROJECT_ROOT/build/DropInstall-x86_64" \
    -output "$APP/Contents/MacOS/DropInstall"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun swiftc "${SWIFT_FLAGS[@]}" "$PROJECT_ROOT/scripts/icon.swift" -o "$PROJECT_ROOT/build/make-icon"
"$PROJECT_ROOT/build/make-icon" "$PROJECT_ROOT/build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$PROJECT_ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Finder/iCloud may add these to locally generated resources; codesign rejects them.
# Only clean build output, never downloaded images or installed third-party apps.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
# Sign and archive outside iCloud/File Provider folders, which can immediately
# re-add FinderInfo after cleanup. Publish only after the local archive verifies.
ARCHIVE="$PACKAGE_STAGE/DropInstall-${VERSION}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/usr/bin/ditto -x -k "$ARCHIVE" "$PACKAGE_STAGE/verify"
/usr/bin/codesign --verify --strict "$PACKAGE_STAGE/verify/DropInstall.app"
/usr/bin/ditto "$APP" "$DELIVERABLE"
cp "$ARCHIVE" "$PROJECT_ROOT/dist/DropInstall-${VERSION}.zip"
echo "Built: $DELIVERABLE"
