#!/usr/bin/env bash
# sign-app.sh APP IDENTITY KEYCHAIN
#
# Signs the app with the certificate whose SHA-1 is IDENTITY, from KEYCHAIN.
# The certificate is self-signed and not trusted, so it is chosen by its
# hash. Inside out, as Sparkle's documentation describes: the XPC services,
# Autoupdate and Updater.app inside Sparkle.framework, then the framework,
# then the app. No hardened runtime and no timestamp: they matter only for
# notarization (docs/adr/0004).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 3 ]] || die "usage: sign-app.sh APP IDENTITY KEYCHAIN"
app=$1 identity=$2 keychain=$3
[[ "$identity" =~ ^[0-9A-F]{40}$ ]] || die "IDENTITY must be a SHA-1 hash, not '$identity'"

# sign [OPTION...] PATH
sign() {
    local path=${!#}
    echo "Signing ${path#"$app"/}" >&2
    codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$@"
}

framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" ]] || die "no Sparkle.framework in $app"
current="$framework/Versions/$(readlink "$framework/Versions/Current")"
[[ -d "$current" ]] || die "Sparkle.framework has no current version"

for helper in "$current/Autoupdate" "$current/Updater.app"; do
    [[ -e "$helper" ]] || die "Sparkle.framework has no $(basename "$helper")"
done

shopt -s nullglob
for service in "$current"/XPCServices/*.xpc; do
    # The Downloader keeps its network entitlement.
    sign --preserve-metadata=entitlements "$service"
done
sign "$current/Autoupdate"
sign "$current/Updater.app"
sign "$framework"

# Anything else embedded, should a later dependency add some.
for other in "$app"/Contents/Frameworks/*; do
    [[ "$other" == "$framework" ]] || sign "$other"
done
shopt -u nullglob

sign "$app"
codesign --verify --deep --strict --verbose=2 "$app"
