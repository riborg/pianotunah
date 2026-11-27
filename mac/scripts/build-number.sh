#!/usr/bin/env bash
# build-number.sh TAG [COMMITS]
#
# Prints the CFBundleVersion for the release TAG: C.99 for a release
# (v1.2.0) and C.N for a pre-release, where C is the number of commits up
# to TAG (or COMMITS, for tests) and N comes from the suffix: its kind
# gives a range, its last number (1 if none, at most 29) the place in it.
#   -alpha.n, -dev.n and any other kind   n       (1–29)
#   -beta.n                               30 + n  (31–59)
#   -rc.n                                 60 + n  (61–89)
#
# Sparkle compares these part by part, so every build is newer than the
# one before: on one commit alpha < beta < rc < the release (C.89 <
# C.99), and that release older than the next commit's (C.99 < C+1.1).
# Two pre-releases of one kind on one commit need different numbers, and
# numbers above 29 count as 29. Builds before v1.14.0 were plain commit
# counts (323), which these are all newer than.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -ge 1 && $# -le 2 ]] || die "usage: build-number.sh TAG [COMMITS]"
tag=$1
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-([0-9A-Za-z.-]+))?$ ]] || die "'$tag' is not a release tag like v1.2.0"
suffix=${BASH_REMATCH[2]}
commits=${2:-$(git -C "$mac_dir" rev-list --count "$tag")}
[[ "$commits" =~ ^[0-9]+$ ]] || die "the commit count must be a whole number, not '$commits'"

if [[ -z "$suffix" ]]; then
    n=99
else
    case $suffix in
        beta*) base=30 ;;
        rc*) base=60 ;;
        *) base=0 ;;
    esac
    number=1
    if [[ "$suffix" =~ ([0-9]+)[^0-9]*$ ]]; then
        number=${BASH_REMATCH[1]}
        number=${number#"${number%%[!0]*}"} # no leading zeros
        # Longer than bash arithmetic can hold: past the cap anyway.
        if (( ${#number} > 2 )); then number=29; else number=$((10#0$number)); fi
    fi
    (( number >= 1 )) || number=1
    (( number <= 29 )) || number=29
    n=$((base + number))
fi
echo "$commits.$n"
