#!/usr/bin/env bash
# select-xcode.sh: selects the newest released Xcode on a GitHub macOS
# runner (/Applications/Xcode_26.6.app and the like; betas are skipped).
# For CI; on your own Mac, use the Xcode you have.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

newest=$(
    for path in /Applications/Xcode_*.app; do
        name=$(basename "$path" .app)
        version=${name#Xcode_}
        [[ "$version" =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]] || continue
        # A sort key like 000260000600000 for 26.6.
        printf '%05d%05d%05d %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}" \
            "${BASH_REMATCH[5]:-0}" "$path"
    done | sort | tail -n 1 | cut -d' ' -f2-
)
[[ -n "$newest" ]] || die "no /Applications/Xcode_*.app found"
sudo xcode-select --switch "$newest/Contents/Developer"
xcodebuild -version
