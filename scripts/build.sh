#!/bin/bash
# Builds a Release DiskFlasher.app into build/Release (git-ignored).
#
#   scripts/build.sh          build the app
#   scripts/build.sh --zip    also write build/Release/DiskFlasher.zip
#   scripts/build.sh --open   reveal the built app in Finder
#
# The app is ad-hoc signed (the project's default), so it runs on this Mac
# but is not notarized.
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="DiskFlasher"
DERIVED_DATA="build/DerivedData"
OUT_DIR="build/Release"
APP="$OUT_DIR/$SCHEME.app"

make_zip=false
open_after=false
for arg in "$@"; do
  case "$arg" in
    --zip) make_zip=true ;;
    --open) open_after=true ;;
    *) echo "usage: $0 [--zip] [--open]" >&2; exit 2 ;;
  esac
done

xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

mkdir -p "$OUT_DIR"
rm -rf "$APP"
ditto "$DERIVED_DATA/Build/Products/Release/$SCHEME.app" "$APP"
echo "Built $APP"

if $make_zip; then
  rm -f "$OUT_DIR/$SCHEME.zip"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/$SCHEME.zip"
  echo "Zipped $OUT_DIR/$SCHEME.zip"
fi

if $open_after; then
  open -R "$APP"
fi
