#!/usr/bin/env bash
# write-appcast.sh ZIP APP OUT.xml
#
# Signs ZIP with Sparkle's sign_update and the private key in
# $SPARKLE_ED_PRIVATE_KEY, and writes the appcast with one item for this
# version to OUT.xml. APP is the signed app that is in the zip; its
# Info.plist gives the version numbers. $TAG is the release's tag (v1.2.0)
# and $REPO its repository (owner/name).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 3 ]] || die "usage: write-appcast.sh ZIP APP OUT.xml"
zip=$1 app=$2 out=$3
: "${TAG:?set TAG to the release tag, e.g. v1.2.0}"
: "${REPO:?set REPO to owner/name}"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is not set"

info="$app/Contents/Info.plist"
build_number=$(plist_value "$info" CFBundleVersion)
version=$(plist_value "$info" CFBundleShortVersionString)
minimum_system=$("$scripts_dir/deployment-target.sh")

# Nothing below is escaped for XML, so make sure nothing needs it.
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "CFBundleVersion '$build_number' is not C or C.N (build-number.sh)"
[[ "$version" == "${TAG#v}" ]] || die "CFBundleShortVersionString '$version' is not the tag $TAG without v"
[[ "$TAG" =~ ^v[0-9A-Za-z.+-]+$ ]] || die "unexpected tag '$TAG'"
[[ "$REPO" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]] || die "unexpected repository '$REPO'"

bin=$(sparkle_bin)
signature=$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$bin/sign_update" --ed-key-file - -p "$zip")
[[ "$signature" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "sign_update gave no signature"
length=$(wc -c < "$zip" | tr -d ' ')

base="https://github.com/$REPO/releases"
pub_date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat > "$out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Piano Tunah</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$version</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$base/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$base/download/$TAG/PianoTunah.zip" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
EOF
echo "Wrote $out for $version ($build_number), macOS $minimum_system or later" >&2
