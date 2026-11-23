#!/usr/bin/env bash
# make-signing-cert.sh OUT.p12 [NAME]
#
# Makes the self-signed code-signing certificate the releases are signed
# with, valid for 10 years, and writes it with its private key to OUT.p12,
# protected by $MAC_SIGNING_PASSWORD. Run once on your Mac (DEVELOP.md); the
# CI dry run makes a throwaway one the same way. A new certificate is a new
# identity for macOS, which then asks for the microphone again, so keep the
# .p12 and make a new one only when this one expires.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

out=${1:?usage: make-signing-cert.sh OUT.p12 [NAME]}
name=${2:-Piano Tunah}
[[ -n "${MAC_SIGNING_PASSWORD:-}" ]] || die "set MAC_SIGNING_PASSWORD to the password for the .p12"
[[ ! -e "$out" ]] || die "$out exists; not overwriting it"

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
CN = $name

[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

# macOS's `security import` reads only the older PKCS#12 encryption. That
# is LibreSSL's default (/usr/bin/openssl); OpenSSL must be told. Any
# OpenSSL, not only 3: 4 and later default to AES too, and a .p12 that
# `security import` rejects is found only when the release job runs. 1.1
# takes the same options.
legacy=()
if openssl version | grep -q '^OpenSSL '; then
    legacy=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
fi
openssl pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$work/cert.pem" \
    -passout env:MAC_SIGNING_PASSWORD ${legacy[@]+"${legacy[@]}"} -out "$out"

echo "Wrote $out:" >&2
openssl x509 -in "$work/cert.pem" -noout -subject -enddate -fingerprint -sha1 >&2
