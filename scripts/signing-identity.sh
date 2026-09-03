#!/bin/bash
# Creates a local, self-signed code-signing identity so the app keeps a stable code identity across rebuilds.
#
# Why: macOS ties an Accessibility grant (and the Keychain grant for Claude Code's login) to the signing identity.
# An ad-hoc signature has none — its hash changes with every build — so every reinstall drops both grants, and
# CompactSide.auto can never hold the permission it needs. A self-signed certificate fixes that locally. It does
# NOT replace a Developer ID: a build handed to anyone else still needs one, for notarisation and Gatekeeper.
#
# Idempotent: does nothing if the identity already exists. Remove it with
#   security delete-identity -c "Notchmeter Local" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="Notchmeter Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# codesign has to be allowed to use the private key without a dialog. That authorisation needs the login
# password, so it cannot be done unattended; this is the one step that asks for it.
if [ "${1:-}" = "--authorise" ]; then
    echo "Authorising codesign to use \"$NAME\" without prompting."
    echo "Enter your macOS login password when asked (it goes to the keychain, nowhere else)."
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null \
      || security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN"
    echo "done — rebuild with scripts/build.sh and it will sign with $NAME"
    exit 0
fi

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "already present: $NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Notchmeter Local
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1
# -legacy and an explicit MAC: Security.framework rejects the bundle OpenSSL 3 writes by default, and a
# non-empty passphrase avoids the empty-password path that fails MAC verification on import.
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout pass:notchmeter 2>/dev/null \
  || openssl pkcs12 -export -macalg sha1 -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout pass:notchmeter

# -A lets codesign use the key without asking each time, which is what keeps this non-interactive.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P notchmeter -A -T /usr/bin/codesign >/dev/null

echo "created: $NAME"
echo
echo "One step left, and it needs your login password:"
echo "  scripts/signing-identity.sh --authorise"
echo "Until then builds stay ad-hoc signed and macOS keeps dropping the Accessibility and Keychain grants."
