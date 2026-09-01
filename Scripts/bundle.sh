#!/bin/bash
#
# Assembles build/Stolnk.app from the SwiftPM executable.
#
# A menu bar app needs a real bundle, not a bare executable: LSUIElement keeps
# it out of the Dock, and UNUserNotificationCenter refuses to work at all
# without a bundle identifier. Development builds are signed ad-hoc, which is
# enough for the Secure Enclave path to work locally. Release builds need a
# Developer ID identity and notarisation (PRD 10.1).
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Stolnk.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
IDENTITY="${CODESIGN_IDENTITY:--}"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/StolnkApp"
if [ ! -x "$BINARY" ]; then
	echo "error: $BINARY not found — run 'swift build -c $CONFIGURATION' first" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/StolnkApp"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/FileGoMenuBarIcon.png" "$APP/Contents/Resources/FileGoMenuBarIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Stolnk</string>
	<key>CFBundleDisplayName</key>
	<string>Stolnk</string>
	<key>CFBundleIdentifier</key>
	<string>com.stolnk.mac</string>
	<key>CFBundleExecutable</key>
	<string>StolnkApp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Menu bar only: no Dock icon, no window at rest. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Stolnk</string>
</dict>
</plist>
PLIST

cat > "$ROOT/build/Stolnk.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Not sandboxed: the whole point is landing files in folders the user
	     picks anywhere on disk, including external volumes (PRD 10.1). -->
	<key>com.apple.security.app-sandbox</key>
	<false/>
</dict>
</plist>
ENTITLEMENTS

codesign --force --sign "$IDENTITY" \
	--entitlements "$ROOT/build/Stolnk.entitlements" \
	--options runtime \
	--timestamp=none \
	"$APP" 2>/dev/null ||
	codesign --force --sign "$IDENTITY" "$APP"

echo "built $APP"
codesign -dv "$APP" 2>&1 | sed -n '1,4p'
