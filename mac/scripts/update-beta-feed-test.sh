#!/usr/bin/env bash
# update-beta-feed-test.sh: checks update-beta-feed.sh. Needs no Mac.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

appcast() { # FILE BUILD
    printf '<rss><channel><item>\n      <sparkle:version>%s</sparkle:version>\n</item></channel></rss>\n' "$2" > "$1"
}
expect_feed() { # BUILD WHY
    if ! grep -q "<sparkle:version>$1</sparkle:version>" "$work/beta.xml"; then
        echo "beta feed not at $1 ($2): $(cat "$work/beta.xml")" >&2
        fail=1
    fi
}

appcast "$work/rc.xml" 340.61
./update-beta-feed.sh "$work/rc.xml" "$work/beta.xml" > /dev/null
expect_feed 340.61 "no feed yet"

appcast "$work/final.xml" 340.99
./update-beta-feed.sh "$work/final.xml" "$work/beta.xml" > /dev/null
expect_feed 340.99 "the release after its rc"

appcast "$work/old.xml" 323
./update-beta-feed.sh "$work/old.xml" "$work/beta.xml" > /dev/null
expect_feed 340.99 "a re-run of an older release"

appcast "$work/next.xml" 341.31
./update-beta-feed.sh "$work/next.xml" "$work/beta.xml" > /dev/null
expect_feed 341.31 "the next beta"

./update-beta-feed.sh "$work/next.xml" "$work/beta.xml" > /dev/null
expect_feed 341.31 "the same build again"

echo '<rss/>' > "$work/empty.xml"
if ./update-beta-feed.sh "$work/empty.xml" "$work/beta.xml" 2> /dev/null; then
    echo "an appcast without a build was accepted" >&2
    fail=1
fi
(( fail == 0 )) && echo "update-beta-feed.sh: ok (bash $BASH_VERSION)"
exit "$fail"
