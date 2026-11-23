#!/usr/bin/env bash
# dry-run.sh: the whole Mac release for a fake v0.0.1, with throwaway keys,
# so the pipeline is proven without the real secrets. CI runs it on every
# push (the release-dry-run job); it also runs on your Mac. Makes a
# certificate with openssl and an EdDSA key with Sparkle's generate_keys, in
# a temporary keychain (the login keychain is not touched), then runs
# release.sh, which ends with check-release.sh. The results are in
# $BUILD_DIR/dist; nothing is uploaded.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

export TAG=v0.0.1
export REPO=${REPO:-${GITHUB_REPOSITORY:-riborg/pianotunah}}
BUILD_NUMBER=$(git -C "$mac_dir" rev-list --count HEAD)
export BUILD_NUMBER

work=$(mktemp -d)
cleanup() {
    keychain_close
    rm -rf "$work"
}
trap cleanup EXIT

echo "== Throwaway code-signing certificate" >&2
MAC_SIGNING_PASSWORD=$(openssl rand -hex 16)
export MAC_SIGNING_PASSWORD
"$scripts_dir/make-signing-cert.sh" "$work/signing.p12" "Piano Tunah Dry Run"
MAC_SIGNING_P12=$(base64 < "$work/signing.p12" | tr -d '\n')
export MAC_SIGNING_P12

echo "== Throwaway EdDSA key" >&2
bin=$(sparkle_bin)
account=pianotunah-dry-run
keychain_open "$work/keys.keychain-db" "$(openssl rand -hex 24)" exclusive
"$bin/generate_keys" --account "$account" >&2
public_key=$("$bin/generate_keys" --account "$account" -p)
"$bin/generate_keys" --account "$account" -x "$work/ed25519.key"
keychain_close
SPARKLE_ED_PRIVATE_KEY=$(cat "$work/ed25519.key")
export SPARKLE_ED_PRIVATE_KEY
derived=$("$scripts_dir/ed-key.sh" public)
[[ "$derived" == "$public_key" ]] ||
    die "ed-key.sh derives $derived, generate_keys says $public_key"
echo "ok    ed-key.sh derives generate_keys's public key $public_key" >&2

"$scripts_dir/release.sh"

out_dir=${OUT_DIR:-$BUILD_DIR/dist}
embedded=$(plist_value "$app_path/Contents/Info.plist" SUPublicEDKey)
[[ "$embedded" == "$public_key" ]] || die "the app carries $embedded, not the throwaway key"
echo "Dry run passed: $out_dir/PianoTunah.zip and $out_dir/appcast.xml" >&2
cat "$out_dir/appcast.xml"
