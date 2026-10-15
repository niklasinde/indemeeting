#!/bin/bash
# Exports the "MeetingRecorder Local" certificate and private key to a password-protected .p12 backup.
# Usage: scripts/export-signing-identity.sh [output.p12]
# Restore on another Mac:
#   security import <file>.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
#   security find-certificate -c "MeetingRecorder Local" -p > cert.pem
#   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
set -euo pipefail
umask 077

NAME="MeetingRecorder Local"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OUT="${1:-$HOME/Documents/MeetingRecorder-Local-signing.p12}"
OPENSSL=/usr/bin/openssl

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "error: no \"$NAME\" signing identity in $KEYCHAIN."
    exit 1
fi
if [ -e "$OUT" ]; then
    echo "error: $OUT already exists."
    exit 1
fi

cat <<WARN
WARNING: keep this file and its password safe (a password manager or an encrypted backup).
Every release is signed with this identity. If it is lost and a new one is made, macOS treats the next
update as a different app and your friends have to grant Microphone and System Audio Recording again.

WARN

read -r -s -p "Password for the .p12: " PASSWORD; echo
read -r -s -p "Repeat the password: " REPEAT; echo
if [ -z "$PASSWORD" ] || [ "$PASSWORD" != "$REPEAT" ]; then
    echo "error: the passwords are empty or do not match."
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
$OPENSSL x509 -in "$WORK/cert.pem" -noout -pubkey > "$WORK/cert.pub"

# security can only export every identity in the keychain; keep the key that belongs to the certificate.
echo "macOS asks to allow exporting keys from the keychain."
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASSWORD" -o "$WORK/all.p12"
$OPENSSL pkcs12 -in "$WORK/all.p12" -passin "pass:$PASSWORD" -nocerts -nodes 2>/dev/null \
    | awk -v dir="$WORK" '/-----BEGIN/ { n++; out = dir "/key" n ".pem" } out { print > out } /-----END/ { out = "" }'

KEY=""
for candidate in "$WORK"/key*.pem; do
    if $OPENSSL pkey -in "$candidate" -pubout 2>/dev/null | cmp -s - "$WORK/cert.pub"; then KEY="$candidate"; break; fi
done
if [ -z "$KEY" ]; then
    echo "error: could not find the private key for \"$NAME\"."
    exit 1
fi

$OPENSSL pkcs12 -export -inkey "$KEY" -in "$WORK/cert.pem" -name "$NAME" -out "$OUT" -passout "pass:$PASSWORD"
echo "Exported \"$NAME\" to $OUT"
