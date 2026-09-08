#!/bin/bash
#
# The full distribution chain (PRD 10.1): universal binary, Developer ID
# signature, notarisation, staple, dmg, verify.
#
# Direct distribution is not a preference — a sandboxed App Store build cannot
# write to folders the user picks anywhere on disk, including external volumes,
# which is the entire product. That leaves Gatekeeper as the thing standing
# between a download and a first launch, and PRD 19 risk #7 names that friction
# as a real drop-off point. Everything in here exists so the user sees exactly
# one ordinary "downloaded from the Internet" dialog and nothing worse.
#
#   ./Scripts/release.sh                  the real thing
#   SKIP_NOTARIZE=1 ./Scripts/release.sh  package and sign, no Apple round trip
#   SKIP_TESTS=1    ./Scripts/release.sh  skip `swift test`
#
# NOTARY_PROFILE names a keychain profile stored by:
#
#   xcrun notarytool store-credentials "stolnk-notary" \
#     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Stolnk.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
DMG="$ROOT/build/Stolnk-$VERSION-universal.dmg"
ZIP="$ROOT/build/Stolnk.app.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-stolnk-notary}"

# Preflight before spending five minutes on a build. Both of these fail at the
# very end otherwise, after the expensive part.
if [ -z "${SKIP_NOTARIZE:-}" ]; then
	if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
		echo "error: no stored notarytool credentials under profile '$NOTARY_PROFILE'." >&2
		echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
		echo "    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \\" >&2
		echo "    --key-id XXXXXXXXXX --issuer <issuer-uuid>" >&2
		echo "  (Run with SKIP_NOTARIZE=1 to package without notarising.)" >&2
		exit 1
	fi
fi
# Which identity signs this build, decided once so the app and the dmg cannot
# end up signed by different ones.
#
# DEVELOPER_ID is what makes this a release. Without it the only thing that can
# still run is SKIP_NOTARIZE=1 packaging — useful for checking that the dmg is
# assembled correctly, and useless for distribution, which is why it says so.
IDENTITY="${CODESIGN_IDENTITY:-$(
	security find-identity -v -p codesigning 2>/dev/null |
		awk -F'"' '/"Developer ID Application: /{print $2; exit}'
)}"
DEVELOPER_ID=1
if [ -z "$IDENTITY" ]; then
	if [ -n "${SKIP_NOTARIZE:-}" ]; then
		DEVELOPER_ID=""
		echo "warning: no 'Developer ID Application' certificate — packaging with" >&2
		echo "         whatever development identity is available. The dmg this" >&2
		echo "         produces is for checking the packaging and nothing else." >&2
	else
		echo "error: no 'Developer ID Application' certificate in the keychain." >&2
		echo "       Create one at developer.apple.com -> Certificates -> + ->" >&2
		echo "       Developer ID Application, for team U26MT4R2WR." >&2
		echo "       Note that 'Apple Distribution' is a different certificate:" >&2
		echo "       it signs App Store and Ad Hoc builds, and notarytool rejects" >&2
		echo "       it for direct distribution." >&2
		exit 1
	fi
fi

echo "==> Stolnk $VERSION"

if [ -z "${SKIP_TESTS:-}" ]; then
	echo "==> swift test"
	swift test
fi

# PRD 8.2 — the WebRTC framework is a remote binary artifact, so a cold machine
# would otherwise discover a ~45 MB download in the middle of the release build.
if ! find "$ROOT/.build/artifacts" -name 'WebRTC.xcframework' -print -quit 2>/dev/null | grep -q .; then
	echo "==> resolving binary dependencies (downloads ~45 MB)"
	swift package resolve
fi

echo "==> building universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

echo "==> assembling and signing $APP"
# RELEASE=1 is what selects the Developer ID identity and --timestamp in
# bundle.sh; without a certificate it would only fail there instead of here.
RELEASE="${DEVELOPER_ID:+1}" UNIVERSAL=1 CONFIGURATION=release VERSION="$VERSION" \
	CODESIGN_IDENTITY="${IDENTITY:-}" "$ROOT/Scripts/bundle.sh"

notarize() {
	# $1 is the path to submit. Prints the submission log command on any status
	# other than Accepted, because that log is the only thing that says why.
	local target="$1"
	local out
	if ! out="$(xcrun notarytool submit "$target" \
		--keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
		echo "$out" >&2
		echo "error: notarytool submit failed for $target" >&2
		exit 1
	fi
	echo "$out"
	if ! grep -q "status: Accepted" <<<"$out"; then
		local id
		id="$(grep -m1 -E '^ *id: ' <<<"$out" | awk '{print $2}')"
		echo "error: notarisation was not accepted for $target" >&2
		echo "  xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
		exit 1
	fi
}

# Pass 1: the .app itself.
#
# Stapling only the dmg would leave the copy in /Applications depending on an
# online Gatekeeper lookup at first launch, so a user on a locked-down or
# offline network still gets the frightening dialog. Two round trips is the
# price of the app opening offline.
if [ -z "${SKIP_NOTARIZE:-}" ]; then
	echo "==> notarising the app (1 of 2)"
	rm -f "$ZIP"
	ditto -c -k --keepParent "$APP" "$ZIP"
	notarize "$ZIP"
	xcrun stapler staple "$APP"
	rm -f "$ZIP"
fi

echo "==> building $DMG"
# -srcfolder has to point at a folder, not at the app: the volume needs the app
# *and* an /Applications symlink, or there is nowhere to drag it to.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto rather than cp -R: it preserves the extended attributes a signed bundle
# carries, which cp -R has been known to drop and thereby invalidate the
# signature.
ditto "$APP" "$STAGE/Stolnk.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# UDZO is the zlib-compressed read-only format every drag-install dmg uses.
# HFS+ rather than APFS because the floor is macOS 13 and APFS buys nothing here.
hdiutil create -volname "Stolnk" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

echo "==> signing the dmg"
if [ -n "$DEVELOPER_ID" ]; then
	codesign --force --sign "$IDENTITY" --timestamp "$DMG"
	codesign --verify --verbose=2 "$DMG"
else
	echo "note: unsigned dmg — no Developer ID certificate." >&2
fi

# Pass 2: the dmg, so the disk image itself opens without a warning.
if [ -z "${SKIP_NOTARIZE:-}" ]; then
	echo "==> notarising the dmg (2 of 2)"
	notarize "$DMG"
	xcrun stapler staple "$DMG"
fi

echo "==> verifying"
lipo -archs "$APP/Contents/MacOS/StolnkApp"
# The embedded framework is the larger half of the bundle and the half signed by
# a separate codesign call, so it gets checked on its own terms: both slices
# present, and a signature of ours rather than the adhoc one it ships with.
lipo -archs "$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
codesign -dv "$APP/Contents/Frameworks/WebRTC.framework" 2>&1 | sed -n '1,4p'
codesign --verify --deep --strict --verbose=2 "$APP"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
	xcrun stapler validate "$APP"
	xcrun stapler validate "$DMG"
	# The two checks that actually model what a stranger's Mac does.
	spctl -a -t exec -vv "$APP"
	spctl -a -t open --context context:primary-signature -vv "$DMG"
else
	echo "note: SKIP_NOTARIZE=1 — this dmg will NOT open cleanly on another Mac." >&2
fi

echo
echo "$DMG"
# Printed, never written to a sidecar file: stolnk/scripts/release-mac.ts
# recomputes it from the dmg, so the file stays the single source of truth and
# there is no second copy to drift.
shasum -a 256 "$DMG"
