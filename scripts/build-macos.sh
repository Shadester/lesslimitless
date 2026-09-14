#!/usr/bin/env bash
set -euo pipefail

# Build, sign, optionally notarize, and optionally package Less Limitless.
# Credentials are deliberately supplied through the keychain/arguments, never this file.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Less Limitless"
EXECUTABLE="LessLimitlessApp"
CONFIGURATION="release"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
MAKE_DMG=0
NOTARIZE=0
RUN_TESTS=0

usage() {
  cat <<'EOF'
Usage: scripts/build-macos.sh [options]

Options:
  --debug                 Build debug instead of release.
  --release               Build release (default).
  --identity IDENTITY     Developer ID Application signing identity. Default: ad-hoc (-).
  --version VERSION       Override CFBundleShortVersionString in the built bundle.
  --build BUILD           Override CFBundleVersion in the built bundle.
  --dmg                   Create dist/Less-Limitless.dmg.
  --notarize              Submit the app/DMG with xcrun notarytool and staple it.
  --notary-profile NAME   notarytool keychain profile (or set NOTARY_PROFILE).
  --test                  Run swift test before building.
  --help                  Show this help.

Environment:
  SIGN_IDENTITY, NOTARY_PROFILE, VERSION, BUILD_NUMBER.

Examples:
  ./scripts/build-macos.sh --debug
  ./scripts/build-macos.sh --identity 'Developer ID Application: Name (TEAMID)' --dmg
  ./scripts/build-macos.sh --identity 'Developer ID Application: Name (TEAMID)' \
      --notary-profile lesslimitless-notary --notarize --dmg
EOF
}

while (($#)); do
  case "$1" in
    --debug) CONFIGURATION="debug" ;;
    --release) CONFIGURATION="release" ;;
    --identity) SIGN_IDENTITY="${2:?missing signing identity}"; shift ;;
    --version) VERSION="${2:?missing version}"; shift ;;
    --build) BUILD_NUMBER="${2:?missing build number}"; shift ;;
    --dmg) MAKE_DMG=1 ;;
    --notarize) NOTARIZE=1 ;;
    --notary-profile) NOTARY_PROFILE="${2:?missing profile}"; shift ;;
    --test) RUN_TESTS=1 ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "This script must run on macOS." >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift/Xcode Command Line Tools are required." >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "pkg-config is required; install libopus with brew install opus." >&2; exit 1; }
command -v install_name_tool >/dev/null || { echo "Xcode Command Line Tools are required." >&2; exit 1; }
command -v codesign >/dev/null || { echo "codesign is required." >&2; exit 1; }
pkg-config --exists opus || { echo "libopus is required: brew install opus" >&2; exit 1; }

if (( NOTARIZE )); then
  [[ "$SIGN_IDENTITY" != "-" ]] || { echo "Notarization requires a Developer ID identity." >&2; exit 1; }
  [[ -n "$NOTARY_PROFILE" ]] || { echo "--notarize requires --notary-profile or NOTARY_PROFILE." >&2; exit 1; }
  command -v xcrun >/dev/null || { echo "xcrun is required for notarization." >&2; exit 1; }
fi

cd "$ROOT"
if (( RUN_TESTS )); then swift test -c "$CONFIGURATION"; fi
swift package resolve
swift build -c "$CONFIGURATION" --product "$EXECUTABLE"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS"
cp "$BIN_DIR/$EXECUTABLE" "$CONTENTS/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -n "$VERSION" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"; fi
if [[ -n "$BUILD_NUMBER" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"; fi

OPUS_LIBDIR="$(pkg-config --variable=libdir opus)"
OPUS_DYLIB="$(find "$OPUS_LIBDIR" -maxdepth 1 -type f -name 'libopus*.dylib' -print -quit)"
[[ -n "$OPUS_DYLIB" ]] || { echo "Could not locate libopus dylib in $OPUS_LIBDIR" >&2; exit 1; }
OPUS_NAME="$(basename "$OPUS_DYLIB")"
cp "$OPUS_DYLIB" "$FRAMEWORKS/$OPUS_NAME"

# Make the executable self-contained rather than referring to a Homebrew path.
while IFS= read -r dependency; do
  [[ "$dependency" == *libopus* ]] || continue
  install_name_tool -change "$dependency" "@executable_path/../Frameworks/$OPUS_NAME" "$CONTENTS/MacOS/$EXECUTABLE"
done < <(otool -L "$CONTENTS/MacOS/$EXECUTABLE" | awk 'NR > 1 {print $1}')
install_name_tool -id "@rpath/$OPUS_NAME" "$FRAMEWORKS/$OPUS_NAME"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$FRAMEWORKS/$OPUS_NAME"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$FRAMEWORKS/$OPUS_NAME"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

OUTPUT="$APP"
if (( MAKE_DMG )); then
  DMG="$DIST/Less-Limitless.dmg"
  STAGE="$DIST/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  OUTPUT="$DMG"
fi

if (( NOTARIZE )); then
  xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT"
  xcrun stapler validate "$OUTPUT"
fi

printf '\nBuilt: %s\n' "$OUTPUT"
printf 'Signing identity: %s\n' "$SIGN_IDENTITY"
