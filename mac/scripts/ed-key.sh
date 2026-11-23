#!/usr/bin/env bash
# The EdDSA key that Sparkle checks updates with.
#
#   ed-key.sh public
#       prints the public key (SUPublicEDKey) of the private key in
#       $SPARKLE_ED_PRIVATE_KEY, so the release needs only the private key
#       as a secret and the two can never disagree
#   ed-key.sh verify FILE SIGNATURE PUBLIC_KEY
#       fails unless SIGNATURE (from sign_update) is FILE's signature by the
#       key whose public half is PUBLIC_KEY
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case "${1:-}" in
    public)
        [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is not set"
        printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | xcrun swift "$scripts_dir/ed-key.swift" public
        ;;
    verify)
        [[ $# -eq 4 ]] || die "usage: ed-key.sh verify FILE SIGNATURE PUBLIC_KEY"
        xcrun swift "$scripts_dir/ed-key.swift" verify "$2" "$3" "$4"
        ;;
    *)
        die "usage: ed-key.sh public | verify FILE SIGNATURE PUBLIC_KEY"
        ;;
esac
