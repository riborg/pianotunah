#!/usr/bin/env bash
# update-beta-feed.sh APPCAST FEED
#
# The beta feed (FEED, beta.xml on the appcast branch) is the appcast of
# the newest build released, pre-release or not: the app reads it instead
# of releases/latest's when "Get beta versions" is on. Copies APPCAST, a
# release's appcast.xml, over FEED unless FEED has a newer build, so a
# re-run of an older release never takes the feed back. Prints what it
# did.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "usage: update-beta-feed.sh APPCAST FEED"
appcast=$1 feed=$2

# The item's sparkle:version; write-appcast.sh writes one item per feed.
build_of() {
    sed -n 's:.*<sparkle\:version>\([0-9.]*\)</sparkle\:version>.*:\1:p' "$1" | head -n 1
}

new=$(build_of "$appcast")
[[ -n "$new" ]] || die "$appcast has no sparkle:version"
if [[ -f "$feed" ]]; then
    old=$(build_of "$feed")
    # sort -V compares dotted numbers part by part, as Sparkle does.
    if [[ -n "$old" && "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" != "$new" ]]; then
        echo "kept $feed at build $old, newer than $new"
        exit 0
    fi
fi
cp "$appcast" "$feed"
echo "wrote build $new to $feed"
