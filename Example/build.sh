#!/bin/bash
# Builds the example into a simulator .app without an Xcode project.
#
# A hand-written project.pbxproj would be one more file to keep correct for no gain: this app exists to be
# run against a local backend and measured, and `swiftc` plus a plist is the whole of what that needs.
#
# The library is compiled here rather than by `swift build` because an *automatic* SwiftPM product emits a
# module and no archive, so there is nothing to link against. Declaring the product static would fix the
# link and change what every consumer of the package gets, which is the wrong trade for a sample's build
# script. This way `Package.swift` stays exactly what a real app sees.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios15.0-simulator"
BUILD="$HERE/.build"
APP="$BUILD/LightSessionExample.app"

rm -rf "$BUILD" && mkdir -p "$BUILD"

# The Objective-C half first: one function that wraps `-[CALayer presentationLayer]` in `@try/@catch`, because
# Swift cannot catch an Objective-C exception and that call can raise. Compiled with clang because swiftc cannot
# compile `.m`, and reached from Swift through the module map the target ships.
SAFE="$HERE/../Sources/LightSessionSafe"
xcrun clang -c -fobjc-arc -isysroot "$SDK" -target "$TARGET" \
  -I "$SAFE/include" -o "$BUILD/LightSessionSafe.o" "$SAFE/LightSessionSafe.m"
xcrun ar rcs "$BUILD/libLightSessionSafe.a" "$BUILD/LightSessionSafe.o"

# The library, as its own module, so the app imports it the way a real app does.
xcrun swiftc \
  -sdk "$SDK" -target "$TARGET" \
  -module-name LightSession \
  -Xcc -fmodule-map-file="$SAFE/include/module.modulemap" -I "$SAFE/include" \
  -emit-module -emit-module-path "$BUILD/LightSession.swiftmodule" \
  -emit-library -static -o "$BUILD/libLightSession.a" \
  $(find "$HERE/../Sources/LightSession" -name '*.swift' | sort)

mkdir -p "$APP"
cp "$HERE/Info.plist" "$APP/Info.plist"

xcrun swiftc \
  -sdk "$SDK" -target "$TARGET" \
  -Xcc -fmodule-map-file="$SAFE/include/module.modulemap" -I "$SAFE/include" \
  -I "$BUILD" -L "$BUILD" -lLightSession -lLightSessionSafe \
  -o "$APP/LightSessionExample" \
  $(find "$HERE/Sources" -name '*.swift' | sort)

echo "built $APP"
