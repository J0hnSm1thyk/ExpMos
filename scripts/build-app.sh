#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
case "${1:-}" in
  "") ARCHITECTURES=("$(uname -m)") ;;
  --universal) ARCHITECTURES=(arm64 x86_64) ;;
  *) echo "Usage: $0 [--universal]" >&2; exit 1 ;;
esac

BINARIES=()
for ARCH in "${ARCHITECTURES[@]}"; do
  BUILD_OPTIONS=(-c release --product ExpMos --arch "$ARCH"
    --scratch-path "$PROJECT_DIR/.build/distribution/$ARCH"
    -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=/ExpMos")
  swift build "${BUILD_OPTIONS[@]}"
  BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
  BINARIES+=("$BIN_DIR/ExpMos")
done

if [[ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  xcrun swift scripts/generate-icon.swift "$PROJECT_DIR/.build/AppIcon.iconset"
  iconutil -c icns "$PROJECT_DIR/.build/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
fi
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.build/app.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/ExpMos.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
xcrun lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/ExpMos"
xcrun strip -S "$STAGED_APP/Contents/MacOS/ExpMos"
cp -X "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp -X "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

APP_DIR="$PROJECT_DIR/dist/ExpMos.app"
mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
echo "Built: $APP_DIR"
