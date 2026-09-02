#!/bin/bash
#
# Creates the self-signed code signing identity that development builds use.
#
# Why bother, when codesign happily takes `-` for an ad-hoc signature: an
# ad-hoc signature carries no designated requirement, so the keychain can only
# pin its access control to the binary's cdhash. Every rebuild produces a new
# cdhash, which invalidates the "Always Allow" the user just granted, and the
# access prompt comes back on the next launch. A certificate-backed signature
# keeps the same identity across rebuilds, so the grant sticks.
#
# This is for local development only. Shipping builds need a real Developer ID
# identity and notarisation (PRD 10.1).
set -euo pipefail

NAME="${DEV_IDENTITY_NAME:-Stolnk Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
	echo "identity \"$NAME\" already exists — nothing to do"
	exit 0
fi

# An Apple Development certificate does the same job and is already trusted, so
# there is nothing to gain from a self-signed one next to it.
if security find-identity -v -p codesigning | grep -q '"Apple Development: '; then
	echo "this Mac already has an Apple Development certificate, which bundle.sh"
	echo "picks up on its own — no self-signed identity needed:"
	security find-identity -v -p codesigning | grep '"Apple Development: '
	exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# codeSigning EKU is what makes the certificate show up in `find-identity
# -p codesigning`; without it codesign will not accept the identity.
cat > "$WORK/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-config "$WORK/openssl.cnf" \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

openssl pkcs12 -export -legacy \
	-inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
	-passout pass: -out "$WORK/identity.p12" 2>/dev/null

# -T /usr/bin/codesign lets codesign use the private key without prompting for
# the keychain password on every single build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
	-T /usr/bin/codesign -T /usr/bin/security

# A self-signed certificate is not trusted for code signing until it is said to
# be. This is the step that asks for your login password, and it is the only
# one — it writes a user-level trust setting, not a system-wide one.
echo "granting code signing trust to \"$NAME\" (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep -F "$NAME"
echo
echo "done — 'make app' will pick this up automatically"
