#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEST_BUILD=$(mktemp -d /tmp/gaojixu-widget-store-tests.XXXXXX)
trap 'rm -rf "$TEST_BUILD"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
SOURCES=(Models AccountingModels GameCatalog HeroStats SavingsStore StorePersistence StoreWidgetSnapshot StoreLedger StoreGoals StoreBattle StoreGameSystems MonthlyLedgerBridge WidgetSnapshot AppTheme)
INPUTS=()
for source in $SOURCES; do INPUTS+=("$ROOT/Sources/$source.swift"); done
swiftc -swift-version 5 -parse-as-library -D UNIT_TEST -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$TEST_BUILD/cache" -framework SwiftUI -framework AppKit -framework Combine \
    -framework CoreText -framework CryptoKit $INPUTS "$ROOT/Tests/StoreWidgetSnapshotRegression.swift" \
    -o "$TEST_BUILD/StoreWidgetSnapshotRegression"
"$TEST_BUILD/StoreWidgetSnapshotRegression"
