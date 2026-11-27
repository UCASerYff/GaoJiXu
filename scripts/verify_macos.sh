#!/usr/bin/env bash
# Run only in an isolated CI checkout or while holding the macOS build lease.
set -euo pipefail

if [[ $# != 2 ]]; then
  echo 'Usage: bash scripts/verify_macos.sh <marketing version> <build number>' >&2
  exit 64
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This check requires an arm64 macOS machine and full Xcode.' >&2
  exit 69
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  preferred=/Applications/Xcode_26.3.app/Contents/Developer
  if [[ -x "$preferred/usr/bin/xcodebuild" ]]; then DEVELOPER_DIR="$preferred"; fi
fi
export DEVELOPER_DIR
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || { echo "Full Xcode not found at $DEVELOPER_DIR." >&2; exit 69; }
echo "Toolchain $DEVELOPER_DIR"
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

# The release builders use a relative build directory. Run them against the
# exact committed source in a disposable directory so existing builds stay intact.
umask 077
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gaojixu-macos-verify.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
SOURCE="$WORK/source"
mkdir -p "$SOURCE" "$WORK/fixtures"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$SOURCE"
echo "Verifying $(git -C "$ROOT" rev-parse HEAD)"
xcrun swiftc --version
export GAOJIXU_DATA_DIR="$WORK/fixtures/Savings"
export GQNS_AUTOLEDGER_TASKS_FILE="$WORK/fixtures/tasks.json"

version_check() {
  local file="$1" version build
  plutil -lint "$file"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$file")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$file")"
  if [[ "$version" != "$2" || "$build" != "$3" ]]; then
    echo "Wrong version in $file ($version+$build, expected $2+$3)" >&2
    return 1
  fi
}

version_check "$SOURCE/Info.plist" "$1" "$2"
version_check "$SOURCE/Widgets/Info.plist" "$1" "$2"
BUILD="$SOURCE/build.noindex"

# Framework compilation uses the production flags and an ad-hoc signature.
# The existing widget builder compiles Release with CODE_SIGNING_ALLOWED=NO.
zsh "$SOURCE/scripts/build_framework.sh"
zsh "$SOURCE/scripts/build_widgets.sh"

# Match the production host link without constructing or signing a release app.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD/cache" -load-plugin-library "$MACROS" -F "$BUILD/Frameworks" \
  -framework Savings -framework AppKit -framework SwiftUI -framework UserNotifications -framework CryptoKit \
  -lsqlite3 -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$SOURCE"/Host/*.swift -o "$BUILD/GaoJiXu"

FRAMEWORK="$BUILD/Frameworks/Savings.framework"
WIDGET="$BUILD/PlugIns/GaoJiXuWidgets.appex"
version_check "$FRAMEWORK/Resources/Info.plist" "$1" "$2"
version_check "$WIDGET/Contents/Info.plist" "$1" "$2"
for binary in "$FRAMEWORK/Savings" "$BUILD/GaoJiXu" "$WIDGET/Contents/MacOS/GaoJiXuWidgets"; do
  [[ "$(xcrun lipo -archs "$binary")" == arm64 ]] || { echo "Expected an arm64 binary at $binary" >&2; exit 1; }
done
xcrun otool -L "$BUILD/GaoJiXu" | grep -F '@rpath/Savings.framework/Versions/A/Savings'

zsh "$SOURCE/scripts/test_finance_integration.sh" all
zsh "$SOURCE/scripts/test_widget_store.sh"
zsh "$SOURCE/scripts/test_widget_contract.sh"
echo "macOS arm64 compilation and isolated regressions passed for $1+$2"
