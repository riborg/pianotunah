#!/usr/bin/env bash
# build-app.sh VERSION BUILD_NUMBER PUBLIC_KEY
#
# Builds the app in Release, unsigned, into $BUILD_DIR, and prints its path.
# VERSION becomes CFBundleShortVersionString, BUILD_NUMBER CFBundleVersion
# (which Sparkle compares) and PUBLIC_KEY SUPublicEDKey. Signing is
# sign-app.sh's job.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ $# -eq 3 ]] || die "usage: build-app.sh VERSION BUILD_NUMBER PUBLIC_KEY"
version=$1 build_number=$2 public_key=$3
[[ "$build_number" =~ ^[0-9]+$ ]] || die "the build number must be a whole number, not '$build_number'"
[[ -n "$public_key" ]] || die "a release build needs the public key, or it would never update"

(
    cd "$mac_dir"
    xcodegen generate --quiet
    rm -rf "$app_path"
    xcodebuild -project PianoTunah.xcodeproj -scheme PianoTunah -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
        -quiet build \
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
        SPARKLE_PUBLIC_KEY="$public_key" \
        CODE_SIGNING_ALLOWED=NO
) >&2

[[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] ||
    die "the build has no Sparkle.framework in $app_path"
echo "$app_path"
