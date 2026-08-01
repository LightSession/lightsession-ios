#!/bin/bash
# Builds the example into an .app without an Xcode project.
#
#   ./build.sh            a simulator build, installed with `simctl`
#   ./build.sh device     a signed build for a real iPhone, installed with `devicectl`
#
# A hand-written project.pbxproj would be one more file to keep correct for no gain: this app exists to be
# run against a local backend and measured, and `swiftc` plus a plist is the whole of what that needs.
#
# The library is compiled here rather than by `swift build` because an *automatic* SwiftPM product emits a
# module and no archive, so there is nothing to link against. Declaring the product static would fix the
# link and change what every consumer of the package gets, which is the wrong trade for a sample's build
# script. This way `Package.swift` stays exactly what a real app sees.
#
# ## Why a device build is not just a different `-target`
#
# It is four things, and missing any one of them ends the same way: `dyld` kills the process at launch with
# `__abort_with_payload`, which says nothing about which of the four was missing.
#
#  * The binary has to be built against the **iPhoneOS** SDK. A simulator binary carries `platform
#    IOSSIMULATOR` and a phone cannot load it at all.
#  * The bundle needs the keys a device install checks — `CFBundleSupportedPlatforms`, `MinimumOSVersion`,
#    `UIDeviceFamily` — which a simulator ignores, so they were never there to be missed.
#  * It has to be signed by a development identity, not by the ad-hoc signature the linker leaves behind.
#  * It has to carry a provisioning profile that names the app and lists the phone — and its bundle id has
#    to be the one that profile authorises. That is why the device build takes its id from the profile
#    rather than from `Info.plist`: an id is not something a build script gets to invent, it has to match
#    one somebody registered.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

MODE=${1:-simulator}
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/.build"
APP="$BUILD/LightSessionExample.app"
SAFE="$HERE/../Sources/LightSessionSafe"

if [ "$MODE" = "device" ]; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  TARGET="arm64-apple-ios15.0"
else
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  TARGET="arm64-apple-ios15.0-simulator"
fi

rm -rf "$BUILD" && mkdir -p "$BUILD"

# The Objective-C half first: one function that wraps `-[CALayer presentationLayer]` in `@try/@catch`, because
# Swift cannot catch an Objective-C exception and that call can raise. Compiled with clang because swiftc cannot
# compile `.m`, and reached from Swift through the module map the target ships.
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

if [ "$MODE" != "device" ]; then
  echo "built $APP"
  exit 0
fi

# ---------------------------------------------------------------- device only

PROFILE=${PROFILE:-$(ls -t "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision 2>/dev/null | head -1)}
if [ -z "${PROFILE:-}" ] || [ ! -f "$PROFILE" ]; then
  echo "no provisioning profile found. Run the sample from Xcode once so it makes one, or pass PROFILE=/path/to.mobileprovision" >&2
  exit 1
fi

# The profile is signed CMS; the payload inside is the plist naming the app, the team and the phones.
security cms -D -i "$PROFILE" > "$BUILD/profile.plist"

BUNDLE_ID="$(python3 -c "
import plistlib, sys
p = plistlib.load(open('$BUILD/profile.plist','rb'))
app_id = p['Entitlements']['application-identifier']
team = p['Entitlements']['com.apple.developer.team-identifier']
print(app_id[len(team) + 1:])")"
PROFILE_INFO="$(python3 -c "
import plistlib
p = plistlib.load(open('$BUILD/profile.plist','rb'))
print(p['Entitlements']['com.apple.developer.team-identifier'], p['ExpirationDate'].date(), len(p.get('ProvisionedDevices') or []))")"

# Signed against the profile's own entitlements rather than a hand-written copy: the two have to agree, and
# writing them twice is how they stop agreeing.
python3 -c "
import plistlib
p = plistlib.load(open('$BUILD/profile.plist','rb'))
plistlib.dump(p['Entitlements'], open('$BUILD/entitlements.plist','wb'))"

# The keys a phone checks and a simulator ignores, plus the id the profile authorises.
python3 -c "
import plistlib
path = '$APP/Info.plist'
info = plistlib.load(open(path,'rb'))
info['CFBundleIdentifier'] = '$BUNDLE_ID'
info['CFBundleSupportedPlatforms'] = ['iPhoneOS']
info['MinimumOSVersion'] = '15.0'
info['UIDeviceFamily'] = [1]
info['DTPlatformName'] = 'iphoneos'
plistlib.dump(info, open(path,'wb'))"

cp "$PROFILE" "$APP/embedded.mobileprovision"

IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
if [ -z "${IDENTITY:-}" ]; then
  echo "no Apple Development identity in the keychain" >&2
  exit 1
fi

xcrun codesign --force --timestamp=none --generate-entitlement-der \
  --sign "$IDENTITY" --entitlements "$BUILD/entitlements.plist" "$APP"

echo "built $APP"
echo "  bundle id  $BUNDLE_ID"
echo "  profile    $(basename "$PROFILE")  (team, expiry, devices: $PROFILE_INFO)"
echo "  install    xcrun devicectl device install app --device <udid> \"$APP\""
