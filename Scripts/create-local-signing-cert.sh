#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity ("Speakeasy-Voice Local")
# in the login keychain. `make local` signs with it so that macOS Accessibility
# and Input Monitoring grants PERSIST across rebuilds.
#
# Why this exists:
#   Ad-hoc signing (CODE_SIGN_IDENTITY=-) gives the app a brand-new fingerprint
#   on every build, so macOS treats each rebuild as a different app and forgets
#   the permission you granted. A stable certificate keeps the same identity, so
#   the grant sticks. Run once per machine; safe to re-run (it no-ops if present).
set -euo pipefail

IDENTITY_NAME="Speakeasy-Voice Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
  echo "✅ Signing identity '$IDENTITY_NAME' already exists. Nothing to do."
  exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY_NAME' (valid 10 years)..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$IDENTITY_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:speakeasy \
  -name "$IDENTITY_NAME" >/dev/null 2>&1

# -A lets codesign use the private key without a keychain prompt on each build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P speakeasy -A -f pkcs12

echo "✅ Created '$IDENTITY_NAME'. Local builds now keep their permissions across rebuilds."
echo "   (One-time note: the first build after this change still needs a fresh grant."
echo "    Remove Speakeasy-Voice from Accessibility + Input Monitoring, relaunch, re-add.)"
