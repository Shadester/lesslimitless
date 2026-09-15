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
SKIP_WHISPER=0
WHISPER_MODEL_URL="${WHISPER_MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin}"
WHISPER_MODEL_NAME="ggml-base.en.bin"

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
  --skip-whisper          Do not bundle whisper.cpp + model (faster local iteration).
  --help                  Show this help.

Environment:
  SIGN_IDENTITY, NOTARY_PROFILE, VERSION, BUILD_NUMBER, WHISPER_MODEL_URL.

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
    --skip-whisper) SKIP_WHISPER=1 ;;
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
if (( ! SKIP_WHISPER )); then
  command -v brew >/dev/null || { echo "Homebrew is required to bundle whisper.cpp (or pass --skip-whisper)." >&2; exit 1; }
  brew --prefix whisper.cpp >/dev/null 2>&1 || { echo "whisper.cpp is required: brew install whisper.cpp (or pass --skip-whisper)." >&2; exit 1; }
  brew --prefix ggml >/dev/null 2>&1 || { echo "ggml is required: brew install ggml (or pass --skip-whisper)." >&2; exit 1; }
  brew --prefix libomp >/dev/null 2>&1 || { echo "libomp is required: brew install libomp (or pass --skip-whisper)." >&2; exit 1; }
fi

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

SIGN_TARGETS=("$FRAMEWORKS/$OPUS_NAME")

if (( ! SKIP_WHISPER )); then
  WHISPER_PREFIX="$(brew --prefix whisper.cpp)"
  GGML_PREFIX="$(brew --prefix ggml)"
  LIBOMP_PREFIX="$(brew --prefix libomp)"

  mkdir -p "$CONTENTS/Resources/models"
  cp "$WHISPER_PREFIX/bin/whisper-cli" "$CONTENTS/Resources/whisper-cli"
  cp "$(readlink -f "$WHISPER_PREFIX/lib/libwhisper.1.dylib" 2>/dev/null || greadlink -f "$WHISPER_PREFIX/lib/libwhisper.1.dylib")" "$FRAMEWORKS/libwhisper.1.dylib"
  cp "$(readlink -f "$GGML_PREFIX/lib/libggml.0.dylib" 2>/dev/null || greadlink -f "$GGML_PREFIX/lib/libggml.0.dylib")" "$FRAMEWORKS/libggml.0.dylib"
  cp "$(readlink -f "$GGML_PREFIX/lib/libggml-base.0.dylib" 2>/dev/null || greadlink -f "$GGML_PREFIX/lib/libggml-base.0.dylib")" "$FRAMEWORKS/libggml-base.0.dylib"
  cp "$(readlink -f "$LIBOMP_PREFIX/lib/libomp.dylib" 2>/dev/null || greadlink -f "$LIBOMP_PREFIX/lib/libomp.dylib")" "$FRAMEWORKS/libomp.dylib"

  install_name_tool -change "@rpath/libwhisper.1.dylib" "@executable_path/../Frameworks/libwhisper.1.dylib" "$CONTENTS/Resources/whisper-cli"
  install_name_tool -change "$GGML_PREFIX/lib/libggml.0.dylib" "@executable_path/../Frameworks/libggml.0.dylib" "$CONTENTS/Resources/whisper-cli"
  install_name_tool -change "$GGML_PREFIX/lib/libggml-base.0.dylib" "@executable_path/../Frameworks/libggml-base.0.dylib" "$CONTENTS/Resources/whisper-cli"

  install_name_tool -id "@loader_path/libwhisper.1.dylib" "$FRAMEWORKS/libwhisper.1.dylib"
  install_name_tool -change "$GGML_PREFIX/lib/libggml.0.dylib" "@loader_path/libggml.0.dylib" "$FRAMEWORKS/libwhisper.1.dylib"
  install_name_tool -change "$GGML_PREFIX/lib/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/libwhisper.1.dylib"

  install_name_tool -id "@loader_path/libggml.0.dylib" "$FRAMEWORKS/libggml.0.dylib"
  install_name_tool -change "@rpath/libggml-base.0.dylib" "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/libggml.0.dylib"

  install_name_tool -id "@loader_path/libggml-base.0.dylib" "$FRAMEWORKS/libggml-base.0.dylib"
  install_name_tool -change "$LIBOMP_PREFIX/lib/libomp.dylib" "@loader_path/libomp.dylib" "$FRAMEWORKS/libggml-base.0.dylib"

  install_name_tool -id "@loader_path/libomp.dylib" "$FRAMEWORKS/libomp.dylib"

  SIGN_TARGETS+=("$FRAMEWORKS/libomp.dylib" "$FRAMEWORKS/libggml-base.0.dylib" "$FRAMEWORKS/libggml.0.dylib" "$FRAMEWORKS/libwhisper.1.dylib" "$CONTENTS/Resources/whisper-cli")

  # Cache the model download; huggingface.co is ~78MB and rarely changes.
  MODEL_CACHE="$ROOT/.build/whisper-model-cache"
  mkdir -p "$MODEL_CACHE"
  if [[ ! -s "$MODEL_CACHE/$WHISPER_MODEL_NAME" ]]; then
    echo "Downloading $WHISPER_MODEL_NAME..."
    curl -fL --progress-bar -o "$MODEL_CACHE/$WHISPER_MODEL_NAME.tmp" "$WHISPER_MODEL_URL"
    mv "$MODEL_CACHE/$WHISPER_MODEL_NAME.tmp" "$MODEL_CACHE/$WHISPER_MODEL_NAME"
  fi
  cp "$MODEL_CACHE/$WHISPER_MODEL_NAME" "$CONTENTS/Resources/models/$WHISPER_MODEL_NAME"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  for target in "${SIGN_TARGETS[@]}"; do codesign --force --sign - "$target"; done
  codesign --force --sign - "$APP"
else
  for target in "${SIGN_TARGETS[@]}"; do codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$target"; done
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
