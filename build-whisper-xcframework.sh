#!/bin/bash
# Device-only xcframework: whisper.cpp + ggml into one static lib.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/whisper.cpp-src"
OUT="$ROOT/whisper.xcframework"
HDR="$ROOT/whisper-headers"

if ! command -v xcodebuild >/dev/null; then
  echo "xcodebuild required (run this on macOS CI)"
  exit 1
fi

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi

cd "$SRC"
rm -rf build-ios-device
cmake -B build-ios-device \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_COREML=OFF

cmake --build build-ios-device --config Release -j "$(sysctl -n hw.ncpu)"

LIBS=()
while IFS= read -r line; do
  LIBS+=("$line")
done <<EOF
$(find build-ios-device -name '*.a' -type f | sort)
EOF
if [ "${#LIBS[@]}" -lt 1 ]; then
  echo "no static libs under build-ios-device"
  find build-ios-device -type f | head
  exit 1
fi
echo "Combining: ${LIBS[*]}"
COMBINED="$ROOT/libwhisper-all.a"
rm -f "$COMBINED"
libtool -static -o "$COMBINED" "${LIBS[@]}"

mkdir -p "$HDR"
cp -f include/whisper.h "$HDR/whisper.h"
# Keep our tiny ggml stubs for the bridging header; they only need typedefs.

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$COMBINED" \
  -headers "$HDR" \
  -output "$OUT"

echo "Built $OUT"
ls -lh "$COMBINED" "$OUT/ios-arm64/libwhisper.a" 2>/dev/null || ls -lh "$OUT"
