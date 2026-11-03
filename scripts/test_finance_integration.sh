#!/bin/zsh
# Run only while this task owns the integration Master's heavy-build lease.
# Every executable/fixture is isolated. No application, real database or WidgetCenter is started.
set -euo pipefail
STAGE=${1:-all}
case "$STAGE" in all|migration|monthly|income|research|tasks|cli) ;; *) echo 'Usage: test_finance_integration.sh [all|migration|monthly|income|research|tasks|cli]' >&2; exit 64 ;; esac
ROOT=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$ROOT/build.noindex/finance-regressions.noindex"
mkdir -p "$BUILD/cache"
SDK=$(xcrun --sdk macosx --show-sdk-path)
FLAGS=(-swift-version 5 -parse-as-library -sdk "$SDK" -target arm64-apple-macosx14.0 -module-cache-path "$BUILD/cache")
SHARED=("$ROOT/Shared/FinanceAuthority.swift" "$ROOT/Shared/MonthlyFinanceModels.swift" "$ROOT/Shared/MonthlyFinanceEngine.swift" "$ROOT/Shared/MonthlyFinanceDatabase.swift" "$ROOT/Shared/MonthlyFinanceMigration.swift")
IMPORT=("$ROOT/Sources/ResearchFundingModels.swift" "$ROOT/Sources/ResearchFundingImport.swift" "$ROOT/Sources/FinanceIntegrationMigration.swift")
if [[ "$STAGE" == all || "$STAGE" == migration ]]; then
    xcrun swiftc $FLAGS -lsqlite3 -framework CryptoKit $SHARED $IMPORT "$ROOT/Tests/FinanceIntegrationMigrationRegression.swift" -o "$BUILD/FinanceIntegrationMigrationRegression"
    "$BUILD/FinanceIntegrationMigrationRegression"
fi
if [[ "$STAGE" == all || "$STAGE" == monthly ]]; then
    xcrun swiftc $FLAGS -lsqlite3 -framework CryptoKit $SHARED "$ROOT/Tests/MonthlyFinanceRegression.swift" -o "$BUILD/MonthlyFinanceRegression"
    "$BUILD/MonthlyFinanceRegression"
fi
SOURCES=(FixedIncomeModels FixedIncomeStore Models AccountingModels GameCatalog HeroStats SavingsStore StorePersistence StoreWidgetSnapshot StoreLedger StoreGoals StoreBattle StoreGameSystems MonthlyLedgerBridge WidgetSnapshot AppTheme)
INPUTS=()
for source in $SOURCES; do INPUTS+=("$ROOT/Sources/$source.swift"); done
if [[ "$STAGE" == all || "$STAGE" == income ]]; then
    xcrun swiftc $FLAGS -D UNIT_TEST -framework SwiftUI -framework AppKit -framework Combine -framework CoreText -framework CryptoKit $INPUTS "$ROOT/Tests/FixedIncomeRegression.swift" -o "$BUILD/FixedIncomeRegression"
    "$BUILD/FixedIncomeRegression"
fi
if [[ "$STAGE" == all || "$STAGE" == research ]]; then
    xcrun swiftc $FLAGS -framework Combine -framework CryptoKit "$ROOT/Shared/FinanceAuthority.swift" "$ROOT/Sources/ResearchFundingModels.swift" "$ROOT/Sources/ResearchFundingImport.swift" "$ROOT/Sources/ResearchFundingStore.swift" "$ROOT/Tests/ResearchFundingRegression.swift" -o "$BUILD/ResearchFundingRegression"
    "$BUILD/ResearchFundingRegression"
fi
if [[ "$STAGE" == all || "$STAGE" == cli ]]; then
    xcrun swiftc $FLAGS -lsqlite3 -framework CryptoKit $SHARED $IMPORT "$ROOT/Tools/IntegrateFinance.swift" -o "$ROOT/build.noindex/IntegrateFinance"
fi
if [[ "$STAGE" == all || "$STAGE" == tasks ]]; then
    xcrun swiftc $FLAGS "$ROOT/Host/AutoLedgerTasks.swift" "$ROOT/Tests/AutoLedgerTaskSafetyRegression.swift" -o "$BUILD/AutoLedgerTaskSafetyRegression"
    "$BUILD/AutoLedgerTaskSafetyRegression"
fi
echo "Finance isolated stage passed: $STAGE"
