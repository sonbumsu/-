#!/bin/bash
# Xcode 없이 Command Line Tools만으로 맥 앱(ScreenLink.app)과 테스트 도구를 빌드한다.
#   ./scripts/build-mac.sh          # release
#   ./scripts/build-mac.sh debug
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# iCloud 폴더 안에서는 확장 속성 때문에 코드 서명이 실패하고,
# 동기화 중에 파일이 바뀌어 빌드가 깨질 수 있어서 바깥 폴더에서 빌드한다.
OUT="${SCREENLINK_BUILD_DIR:-$HOME/Library/Caches/ScreenLink/build}"
SRC="$OUT/src"
APP="$OUT/ScreenLink.app"

rm -rf "$SRC"
mkdir -p "$SRC"
cp -R Shared Mac Tests Tools "$SRC/"

ARCH="$(uname -m)"
FLAGS=(-target "$ARCH-apple-macos14.0" -parse-as-library -swift-version 5)
if [ "$CONFIG" = "release" ]; then FLAGS+=(-O); else FLAGS+=(-Onone); fi

echo "▶ ScreenLink.app 빌드 ($CONFIG)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc "${FLAGS[@]}" \
  -import-objc-header "$SRC/Mac/Bridging/CGVirtualDisplay.h" \
  "$SRC"/Shared/*.swift "$SRC"/Mac/*.swift \
  -framework CoreGraphics -framework ScreenCaptureKit -framework VideoToolbox \
  -o "$APP/Contents/MacOS/ScreenLink"
sed -e 's/$(EXECUTABLE_NAME)/ScreenLink/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.sonbumsu.screenlink.host/' \
    Mac/Info.plist > "$APP/Contents/Info.plist"
xattr -cr "$APP"
# 로컬 실행용 ad-hoc 서명. 다시 빌드하면 서명이 바뀌어서 화면 기록 권한을 다시 허용해야 할 수 있다.
codesign --force --sign - --identifier com.sonbumsu.screenlink.host "$APP"

echo "▶ 테스트 도구 빌드"
swiftc "${FLAGS[@]}" "$SRC"/Shared/*.swift "$SRC/Tests/SelfTest.swift" \
  "$SRC/Mac/VideoEncoder.swift" "$SRC/Mac/InputInjector.swift" \
  -framework VideoToolbox -o "$OUT/selftest"
swiftc "${FLAGS[@]}" "$SRC"/Shared/*.swift "$SRC/Tools/Probe.swift" -framework VideoToolbox -o "$OUT/probe"

echo "✅ 완료"
echo "   앱:     $APP"
echo "   테스트: $OUT/selftest"
echo "   probe:  $OUT/probe"
