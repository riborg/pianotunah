#!/usr/bin/env bash
# Prints the app's deployment target, options.deploymentTarget.macOS in
# mac/project.yml, the one place it is set. The appcast's
# sparkle:minimumSystemVersion is read from here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

target=$(awk '
    /^[[:space:]]*(#|$)/ { next }
    {
        match($0, /^ */)
        indent = RLENGTH
        key = $1
    }
    indent == 0 { section = key; sub_section = ""; next }
    section == "options:" && indent == 2 { sub_section = key; next }
    section == "options:" && sub_section == "deploymentTarget:" && key == "macOS:" {
        value = $2
        gsub(/["\047]/, "", value)
        print value
        exit
    }
' "$mac_dir/project.yml")

[[ "$target" =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
    die "options.deploymentTarget.macOS not found in mac/project.yml (got '$target')"
echo "$target"
