#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
STAGE_BUILD=$(mktemp -d /tmp/gaojixu-stage-widget-build.XXXXXX)
trap 'rm -rf "$STAGE_BUILD"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
SOURCES=(Models AccountingModels GameCatalog HeroStats SavingsStore StorePersistence StoreWidgetSnapshot StoreLedger StoreGoals StoreBattle StoreGameSystems MonthlyLedgerBridge WidgetSnapshot AppTheme)
INPUTS=()
for source in $SOURCES; do INPUTS+=("$ROOT/Sources/$source.swift"); done
# UNIT_TEST disables app observers and WidgetKit. This command never opens the application.
# Embed the release metadata so production snapshot provenance identifies the source version/build.
swiftc -swift-version 5 -parse-as-library -D UNIT_TEST -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$STAGE_BUILD/cache" -framework SwiftUI -framework AppKit -framework Combine \
    -framework CoreText -framework CryptoKit $INPUTS "$ROOT/Tools/StageWidgetSnapshot.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$ROOT/Info.plist" \
    -o "$STAGE_BUILD/StageWidgetSnapshot"
"$STAGE_BUILD/StageWidgetSnapshot" "$@"
