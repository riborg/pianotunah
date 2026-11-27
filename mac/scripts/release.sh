#!/usr/bin/env bash
# release.sh: the Mac part of a release, as the release workflow's `mac` job
# runs it (docs/macos-port.md, step 6). Builds the app in Release, signs it,
# zips it, signs the zip for Sparkle, writes the appcast and checks the lot.
# Writes $OUT_DIR/PianoTunah.zip and $OUT_DIR/appcast.xml.
#
# Environment:
#   TAG                     the tag, v1.2.0 or v1.2.0-rc.1
#   REPO                    owner/name (default: $GITHUB_REPOSITORY)
#   BUILD_NUMBER            CFBundleVersion (default: build-number.sh's for
#                           TAG, which grows with every release and rc)
#   MAC_SIGNING_P12         the code-signing certificate and key, base64
#   MAC_SIGNING_PASSWORD    the .p12's password
#   SPARKLE_ED_PRIVATE_KEY  Sparkle's private EdDSA key (generate_keys -x)
#   OUT_DIR                 default: $BUILD_DIR/dist
#
# The certificate goes into a temporary keychain that is deleted at the
# end; the login keychain is not touched. dry-run.sh runs this with
# throwaway keys.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

: "${TAG:?set TAG to the release tag, e.g. v1.2.0}"
REPO=${REPO:-${GITHUB_REPOSITORY:-}}
: "${REPO:?set REPO to owner/name}"
export TAG REPO
for secret in MAC_SIGNING_P12 MAC_SIGNING_PASSWORD SPARKLE_ED_PRIVATE_KEY; do
    [[ -n "${!secret:-}" ]] || die "$secret is not set"
done
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "'$TAG' is not a release tag like v1.2.0"
version=${TAG#v}
build_number=${BUILD_NUMBER:-$("$scripts_dir/build-number.sh" "$TAG")}
out_dir=${OUT_DIR:-$BUILD_DIR/dist}

echo "== Piano Tunah $version, build $build_number, for macOS $("$scripts_dir/deployment-target.sh") or later" >&2

public_key=$("$scripts_dir/ed-key.sh" public)
echo "== Build (SUPublicEDKey $public_key)" >&2
app=$("$scripts_dir/build-app.sh" "$version" "$build_number" "$public_key")

echo "== Sign" >&2
work=$(mktemp -d)
cleanup() {
    keychain_close
    rm -rf "$work"
}
trap cleanup EXIT
keychain_password=$(openssl rand -hex 24)
keychain="$work/signing.keychain-db"
keychain_open "$keychain" "$keychain_password"
printf '%s' "$MAC_SIGNING_P12" | base64 --decode > "$work/signing.p12"
security import "$work/signing.p12" -k "$keychain" -f pkcs12 \
    -P "$MAC_SIGNING_PASSWORD" -T /usr/bin/codesign >&2
rm -f "$work/signing.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$keychain_password" "$keychain" > /dev/null
# Without -v: -v lists only trusted identities, and this one is self-signed.
identities=$(security find-identity -p codesigning "$keychain" |
    grep -E '^[[:space:]]*[0-9]+\)' | grep -Eo '[0-9A-F]{40}' | sort -u)
[[ -n "$identities" ]] || die "no code-signing identity in MAC_SIGNING_P12"
[[ $(printf '%s\n' "$identities" | wc -l) -eq 1 ]] || die "MAC_SIGNING_P12 holds more than one identity"
echo "Identity $identities" >&2
"$scripts_dir/sign-app.sh" "$app" "$identities" "$keychain"

echo "== Zip and appcast" >&2
rm -rf "$out_dir"
mkdir -p "$out_dir"
ditto -c -k --keepParent "$app" "$out_dir/PianoTunah.zip"
"$scripts_dir/write-appcast.sh" "$out_dir/PianoTunah.zip" "$app" "$out_dir/appcast.xml"

echo "== Check" >&2
"$scripts_dir/check-release.sh" "$out_dir"
