#!/bin/bash
#
# Assembles build/Stolnk.app from the SwiftPM executable.
#
# A menu bar app needs a real bundle, not a bare executable: LSUIElement keeps
# it out of the Dock, and UNUserNotificationCenter refuses to work at all
# without a bundle identifier. Release builds need a Developer ID identity and
# notarisation (PRD 10.1) — that is what RELEASE=1 selects for, and
# Scripts/release.sh is the only thing that sets it.
#
#   CONFIGURATION=debug   build the localhost-facing configuration
#   UNIVERSAL=1           expect an arm64 + x86_64 binary, and insist on it
#   RELEASE=1             Developer ID identity and a secure timestamp
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Stolnk.app"

# One version number for the whole chain. Scripts/release.sh reads the same file
# and names the dmg from it, and stolnk/scripts/release-mac.ts cross-checks the
# filename against it — so a release where the plist and the dmg disagree is not
# a thing that can happen quietly.
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
# CFBundleVersion has to increase monotonically across releases, and Apple
# accepts exactly three dot-separated integers — which the marketing version
# already is. Deriving it removes a second number to forget to bump.
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"

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
elif [ "${RELEASE:-}" = "1" ]; then
	# Match the literal prefix, never "the first non-development identity".
	# "Apple Distribution: …" is on this machine and reads like the distribution
	# certificate; it is not. It signs App Store and Ad Hoc builds, and
	# notarytool rejects it for direct distribution.
	IDENTITY="$(
		security find-identity -v -p codesigning 2>/dev/null |
			awk -F'"' '/"Developer ID Application: /{print $2; exit}'
	)"
	if [ -z "$IDENTITY" ]; then
		echo "error: no 'Developer ID Application' certificate in the keychain." >&2
		echo "       Create one at developer.apple.com -> Certificates -> + ->" >&2
		echo "       Developer ID Application, for team U26MT4R2WR, then" >&2
		echo "       double-click the .cer to install it." >&2
		exit 1
	fi
	echo "signing with $IDENTITY"
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

# `--show-bin-path` answers for the flags it is given: bare it reports
# .build/arm64-apple-macosx/release, and with --arch twice it reports
# .build/apple/Products/Release. So the arch flags have to be identical for the
# build and for the query, which is why they live in one array.
#
# `--arch` still parses on Swift 6.2.3 but no longer appears in `swift build
# --help`, which lists only --triple and --swift-sdk. The lipo assertion below
# is what turns a toolchain that quietly drops it into a loud failure rather
# than an arm64-only file named "universal".
ARCHS=()
if [ "${UNIVERSAL:-}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
# macOS ships bash 3.2, where "${ARR[@]}" on an empty array trips `set -u`.
# The `+` expansion is the portable way to say "expand, or nothing at all".
BIN_DIR="$(swift build -c "$CONFIGURATION" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
BINARY="$BIN_DIR/StolnkApp"
RESOURCE_BUNDLE="$BIN_DIR/Stolnk_StolnkApp.bundle"

if [ ! -x "$BINARY" ]; then
	echo "error: $BINARY not found — run 'swift build -c $CONFIGURATION' first" >&2
	exit 1
fi
if [ ! -d "$RESOURCE_BUNDLE" ]; then
	echo "error: $RESOURCE_BUNDLE not found — the menu bar icon would be missing" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/StolnkApp"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM emits the target's declared resources as a bundle next to the
# executable. Copying it into Contents/Resources is what lets `Bundle.module`
# resolve inside the app exactly as it does for a bare `swift run` build.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

if [ "${UNIVERSAL:-}" = "1" ]; then
	SLICES="$(lipo -archs "$APP/Contents/MacOS/StolnkApp")"
	for want in arm64 x86_64; do
		case " $SLICES " in
			*" $want "*) ;;
			*) echo "error: no $want slice — built $SLICES, expected arm64 x86_64" >&2; exit 1 ;;
		esac
	done
	echo "architectures: $SLICES"
fi

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

# Three explicit cases and deliberately no `|| codesign ...` fallback. The
# fallback this replaces re-signed with neither the hardened runtime nor the
# entitlements and still printed "built", which is how an unnotarisable — or
# worse, subtly different — bundle gets shipped without anyone noticing.
if [ "$IDENTITY" = "-" ]; then
	# Ad-hoc carries no certificate, so it can neither take a secure timestamp
	# nor meaningfully assert a hardened runtime. Local development only.
	codesign --force --sign - \
		--entitlements "$ROOT/build/Stolnk.entitlements" \
		"$APP"
elif [ "${RELEASE:-}" = "1" ]; then
	# --timestamp, not --timestamp=none. Without Apple's timestamp server the
	# signature stops validating the day the certificate expires — turning every
	# copy already installed into a "damaged" app — and notarisation refuses the
	# upload outright.
	codesign --force --sign "$IDENTITY" \
		--identifier com.nbtxy.stolnk \
		--entitlements "$ROOT/build/Stolnk.entitlements" \
		--options runtime \
		--timestamp \
		"$APP"
else
	# Same shape as a release, minus the round trip to Apple's timestamp server
	# on every `make app`.
	codesign --force --sign "$IDENTITY" \
		--identifier com.nbtxy.stolnk \
		--entitlements "$ROOT/build/Stolnk.entitlements" \
		--options runtime \
		--timestamp=none \
		"$APP"
fi

codesign --verify --strict --verbose=2 "$APP"

echo "built $APP"
codesign -dv "$APP" 2>&1 | sed -n '1,4p'
