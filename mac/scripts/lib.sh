# shellcheck shell=bash
# Sourced by the release scripts in this folder (docs/macos-port.md, step 6).
# Written for the bash 3.2 that macOS ships: no mapfile, and no empty array
# expansions under `set -u`.

die() {
    echo "error: $*" >&2
    exit 1
}

scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mac_dir=$(dirname "$scripts_dir")

# Everything the scripts build or download goes here (ignored by git).
: "${BUILD_DIR:=$mac_dir/build}"
export BUILD_DIR

# Where the release build puts the app.
# shellcheck disable=SC2034 # used by the scripts that source this
app_path="$BUILD_DIR/DerivedData/Build/Products/Release/PianoTunah.app"

# The keychains in the user's search list, one per line, without quotes.
keychain_search_list() {
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

# keychain_open PATH PASSWORD [exclusive]
#
# Creates a temporary keychain at PATH, unlocked, and puts it first in the
# user's search list. With "exclusive" it is the only keychain searched and
# the default keychain, so that tools which store items in the default
# keychain (Sparkle's generate_keys) never touch the login keychain.
# keychain_close puts the search list and the default keychain back.
keychain_open() {
    local path=$1 password=$2 mode=${3:-}
    saved_search_list=$(keychain_search_list)
    saved_default=$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
    opened_keychain=$path

    security create-keychain -p "$password" "$path"
    security set-keychain-settings -lut 21600 "$path"
    security unlock-keychain -p "$password" "$path"
    if [[ "$mode" == exclusive ]]; then
        security list-keychains -d user -s "$path"
        security default-keychain -d user -s "$path"
    else
        # Word splitting is wanted: one keychain path per line, no spaces
        # in the paths macOS uses.
        # shellcheck disable=SC2086
        security list-keychains -d user -s "$path" $saved_search_list
    fi
}

keychain_close() {
    [[ -n "${opened_keychain:-}" ]] || return 0
    if [[ -n "${saved_default:-}" ]]; then
        security default-keychain -d user -s "$saved_default" || true
    fi
    # shellcheck disable=SC2086
    security list-keychains -d user -s $saved_search_list || true
    security delete-keychain "$opened_keychain" 2>/dev/null || true
    opened_keychain=
}

# The directory with Sparkle's tools (sign_update, generate_keys), from the
# same Swift package as the framework in the app. Resolves the packages
# first, into the folder build-app.sh builds with.
sparkle_bin() {
    (
        cd "$mac_dir"
        xcodegen generate --quiet
        xcodebuild -resolvePackageDependencies -project PianoTunah.xcodeproj \
            -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
    ) >&2 || die "could not resolve the Swift packages"
    local tool
    tool=$(find "$BUILD_DIR/SourcePackages/artifacts" -type f -name sign_update -path '*/bin/*' | head -n 1)
    [[ -n "$tool" ]] || die "Sparkle's sign_update not found under $BUILD_DIR/SourcePackages/artifacts"
    dirname "$tool"
}

# Reads a key from an Info.plist.
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}
