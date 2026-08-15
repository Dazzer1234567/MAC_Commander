#!/bin/bash
# Creates a self-signed code-signing identity so rebuilds keep the same identity
# in the eyes of macOS, and folder-access permissions stop being asked for
# after every build. Run once; build.sh picks the identity up automatically.
set -euo pipefail

NAME="MAC Commander Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "Identity \"$NAME\" already exists — nothing to do."
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
	-subj "/CN=$NAME" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$TMP/cert.p12" \
	-inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
	-passout pass:

echo "==> importing into your login keychain"
echo "    (macOS may ask for your login password)"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "" \
	-T /usr/bin/codesign -T /usr/bin/security

echo "==> marking it trusted for code signing"
echo "    (this one needs an admin password)"
sudo security add-trusted-cert -d -r trustRoot \
	-p codeSign -k /Library/Keychains/System.keychain "$TMP/cert.pem"

# Stops the keychain prompting for permission on every signature.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
	-s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "Done. Rebuild with ./build.sh and grant folder access one final time."
else
	echo "The identity did not register. Sign manually via Keychain Access:"
	echo "  Certificate Assistant > Create a Certificate,"
	echo "  name \"$NAME\", type 'Code Signing', self-signed."
fi
