#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex"
mkdir -p "$BUILD/PlugIns" "$BUILD/widget-cache"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")

xcodebuild -quiet -project "$ROOT/Widgets/GaoJiXuWidgets.xcodeproj" -scheme GaoJiXuWidgets -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD/widget-derived.noindex" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$BUILD/widget-products" OBJROOT="$BUILD/widget-objects" MODULE_CACHE_DIR="$BUILD/widget-cache" CLANG_MODULE_CACHE_PATH="$BUILD/widget-cache" SWIFT_MODULE_CACHE_PATH="$BUILD/widget-cache" SHARED_PRECOMPS_DIR="$BUILD/widget-cache/precompiled" INDEX_ENABLE_DATA_STORE=NO build
ditto "$BUILD/widget-products/Release/GaoJiXuWidgets.appex" "$BUILD/PlugIns/GaoJiXuWidgets.appex"
cp "$ROOT/Widgets/Info.plist" "$BUILD/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUILD/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$BUILD/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist"
