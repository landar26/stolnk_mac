#!/bin/bash
#
# Assembles build/Stolnk.app from the SwiftPM executable.
#
# A menu bar app needs a real bundle, not a bare executable: LSUIElement keeps
# it out of the Dock, and UNUserNotificationCenter refuses to work at all
# without a bundle identifier. Release builds need a Developer ID identity and
# notarisation (PRD 10.1).
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Stolnk.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Any certificate-backed identity beats an ad-hoc signature here. Ad-hoc carries
# no designated requirement, so the keychain can only pin its access grant to the
# binary's cdhash; every rebuild changes the cdhash, invalidates the grant, and
# the device-key prompt comes back. A certificate gives a requirement that names
# the certificate instead, which survives rebuilds.
#
# An Apple Development certificate — the kind Xcode installs — needs no
# provisioning profile for this app, since the only entitlement is a negative
# app-sandbox. Scripts/dev-identity.sh covers machines without one.
DEV_IDENTITY_NAME="${DEV_IDENTITY_NAME:-Stolnk Dev}"
APPLE_DEV_IDENTITY="$(
	security find-identity -v -p codesigning 2>/dev/null |
		awk -F'"' '/"Apple Development: /{print $2; exit}'
)"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
	IDENTITY="$CODESIGN_IDENTITY"
elif [ -n "$APPLE_DEV_IDENTITY" ]; then
	# Pin a specific one with CODESIGN_IDENTITY if this machine has several:
	# switching between them changes the requirement and costs one more prompt.
	IDENTITY="$APPLE_DEV_IDENTITY"
	echo "signing with $IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEV_IDENTITY_NAME"; then
	IDENTITY="$DEV_IDENTITY_NAME"
else
	IDENTITY="-"
	echo "note: signing ad-hoc — no code signing certificate found, so the" \
		"keychain prompt will come back after every build." \
		"Run ./Scripts/dev-identity.sh to fix that." >&2
fi

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/StolnkApp"
if [ ! -x "$BINARY" ]; then
	echo "error: $BINARY not found — run 'swift build -c $CONFIGURATION' first" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/StolnkApp"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM emits the target's declared resources as a bundle next to the
# executable. Copying it into Contents/Resources is what lets `Bundle.module`
# resolve inside the app exactly as it does for a bare `swift run` build.
cp -R "$(dirname "$BINARY")/Stolnk_StolnkApp.bundle" "$APP/Contents/Resources/"

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
	<string>com.nbtxy.stolnk</string>
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
