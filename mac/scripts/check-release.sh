#!/usr/bin/env bash
# check-release.sh DIR
#
# Checks DIR/PianoTunah.zip and DIR/appcast.xml as an installed app would
# meet them: the app in the zip is signed throughout with one identity, its
# Info.plist points at the feed and carries the public key, and the appcast
# describes this zip, with a signature that the app's own key accepts.
# $TAG and $REPO as for write-appcast.sh. Run by release.sh before anything
# is uploaded.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

dir=${1:?usage: check-release.sh DIR}
: "${TAG:?set TAG to the release tag}"
: "${REPO:?set REPO to owner/name}"
zip="$dir/PianoTunah.zip"
appcast="$dir/appcast.xml"
[[ -f "$zip" && -f "$appcast" ]] || die "$dir must hold PianoTunah.zip and appcast.xml"

failures=0
check() { # check WHAT ACTUAL EXPECTED
    if [[ "$2" == "$3" ]]; then
        echo "ok    $1: $2"
    else
        echo "FAIL  $1: '$2', expected '$3'"
        failures=$((failures + 1))
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ditto -x -k "$zip" "$work"
check "zip content" "$(ls "$work")" "PianoTunah.app"
app="$work/PianoTunah.app"
info="$app/Contents/Info.plist"
version=${TAG#v}
minimum_system=$("$scripts_dir/deployment-target.sh")
base="https://github.com/$REPO/releases"

# The app.
codesign --verify --deep --strict --verbose=2 "$app"
authority() { codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -n 1; }
signer=$(authority "$app")
[[ -n "$signer" ]] || { echo "FAIL  the app is not signed with a certificate"; failures=$((failures + 1)); }
framework="$app/Contents/Frameworks/Sparkle.framework"
current="$framework/Versions/$(readlink "$framework/Versions/Current")"
for code in "$framework" "$current/Autoupdate" "$current/Updater.app" "$current"/XPCServices/*.xpc; do
    check "signer of ${code#"$app"/}" "$(authority "$code")" "$signer"
done
check "CFBundleShortVersionString" "$(plist_value "$info" CFBundleShortVersionString)" "$version"
check "LSMinimumSystemVersion" "$(plist_value "$info" LSMinimumSystemVersion)" "$minimum_system"
check "SUFeedURL" "$(plist_value "$info" SUFeedURL)" "$base/latest/download/appcast.xml"
public_key=$(plist_value "$info" SUPublicEDKey)
[[ -n "$public_key" ]] || { echo "FAIL  SUPublicEDKey is empty"; failures=$((failures + 1)); }

# The appcast.
xmllint --noout "$appcast"
xpath() { xmllint --xpath "$1" "$appcast"; }
item='/rss/channel/item'
enclosure="$item/enclosure"
check "items" "$(xpath "count($item)")" "1"
check "sparkle:version" "$(xpath "string($item/*[local-name()='version'])")" "$(plist_value "$info" CFBundleVersion)"
check "sparkle:shortVersionString" "$(xpath "string($item/*[local-name()='shortVersionString'])")" "$version"
check "sparkle:minimumSystemVersion" "$(xpath "string($item/*[local-name()='minimumSystemVersion'])")" "$minimum_system"
check "sparkle:releaseNotesLink" "$(xpath "string($item/*[local-name()='releaseNotesLink'])")" "$base/tag/$TAG"
check "enclosure url" "$(xpath "string($enclosure/@url)")" "$base/download/$TAG/PianoTunah.zip"
check "enclosure length" "$(xpath "string($enclosure/@length)")" "$(wc -c < "$zip" | tr -d ' ')"
signature=$(xpath "string($enclosure/@*[local-name()='edSignature'])")
if [[ -z "$signature" ]]; then
    echo "FAIL  sparkle:edSignature is missing"
    failures=$((failures + 1))
elif [[ -n "$public_key" ]] && "$scripts_dir/ed-key.sh" verify "$zip" "$signature" "$public_key"; then
    echo "ok    sparkle:edSignature matches the app's SUPublicEDKey"
else
    echo "FAIL  sparkle:edSignature does not match the app's SUPublicEDKey"
    failures=$((failures + 1))
fi

[[ $failures -eq 0 ]] || die "$failures check(s) failed"
echo "The release in $dir is consistent."
