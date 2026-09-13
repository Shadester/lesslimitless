#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="Less Limitless"
BUNDLE="$ROOT/.build/app/$APP_NAME.app"
CONTENTS="$BUNDLE/Contents"

cd "$ROOT"
swift build --configuration "$CONFIGURATION" --product LessLimitlessApp
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/LessLimitlessApp" "$CONTENTS/MacOS/LessLimitlessApp"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --timestamp=none "$BUNDLE"
fi

printf 'Built %s\n' "$BUNDLE"
