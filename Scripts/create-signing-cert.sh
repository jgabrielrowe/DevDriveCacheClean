#!/usr/bin/env bash
# One-time: create a self-signed code-signing identity in the login keychain.
#
# No key material enters the repository. The private key lives in the keychain
# and codesign references the identity by name, so the repo needs a string.
set -euo pipefail

NAME="${1:-DevDriveCacheClean Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
  echo "identity '$NAME' already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Absolute path, not whatever "openssl" resolves to in PATH, so the behaviour
# does not depend on whether a Homebrew OpenSSL is installed ahead of it.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# The passphrase must not be empty. Measured 2026-08-12: macOS's importer
# rejects an empty-passphrase PKCS#12 with "MAC verification failed during
# PKCS12 import (wrong password?)" — a misleading error, since the password is
# correct and there is nothing wrong with the MAC. The identical certificate
# imports cleanly with any non-empty passphrase. This one is random, exists
# only inside a 0700 temp directory, and is discarded when the script exits.
P12_PASS="$(/usr/bin/openssl rand -base64 24)"

/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:"$P12_PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Without this, codesign raises a keychain-authorization dialog on every build.
# This is a GUI dialog, not a terminal prompt, like the trust step below.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "note: could not set the key partition list; codesign may prompt on first use" >&2

# Trusting the certificate raises a GUI authorization dialog for your login password.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "created '$NAME'"
echo
echo "Up to two GUI authorization dialogs may have appeared just now, each"
echo "prompting for your login password: one to allow codesign to use the"
echo "key without asking again, and one to trust the certificate."
echo
echo "To use it, run:"
echo "  echo 'export DDCC_SIGNING_IDENTITY=\"$NAME\"' > Scripts/signing.local.sh"
