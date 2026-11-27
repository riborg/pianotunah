#!/usr/bin/env bash
# build-number-test.sh: checks build-number.sh, and that its numbers grow in
# the order releases are made. Needs no Mac; run by CI's swift job.
set -euo pipefail
cd "$(dirname "$0")"
fail=0
expect() {
    local got
    got=$(./build-number.sh "$1" "$2")
    if [[ "$got" != "$3" ]]; then
        echo "build-number.sh $1 $2: got $got, want $3" >&2
        fail=1
    fi
}
expect v1.14.0 340 340.99
expect v1.14.0-alpha.2 340 340.2
expect v1.14.0-dev.3 340 340.3
expect v1.14.0-beta 340 340.31
expect v1.14.0-beta.12 340 340.42
expect v1.14.0-rc.1 340 340.61
expect v1.14.0-rc.0 340 340.61
expect v1.14.0-rc.09 340 340.69
expect v1.14.0-rc.009 340 340.69
expect v1.14.0-rc.250 340 340.89
expect v1.14.0-rc.99999999999999999999 340 340.89

# Oldest first, as they would be released; each must be newer than the last
# (sort -V orders dotted numbers part by part, as Sparkle does).
order=(323 340.2 340.42 340.61 340.89 340.99 341.1 341.99 1000.1)
sorted=$(printf '%s\n' "${order[@]}" | sort -V)
if [[ "$sorted" != "$(printf '%s\n' "${order[@]}")" ]]; then
    echo "build numbers do not grow in release order:" >&2
    echo "$sorted" >&2
    fail=1
fi

if ./build-number.sh 1.14.0 340 2> /dev/null; then
    echo "build-number.sh accepted a tag without v" >&2
    fail=1
fi
(( fail == 0 )) && echo "build-number.sh: ok (bash $BASH_VERSION)"
exit "$fail"
