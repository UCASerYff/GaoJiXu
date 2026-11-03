#!/bin/zsh
set -euo pipefail
umask 077
root=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
work=$(mktemp -d /private/tmp/gaojixu-research-funding.XXXXXX)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk" \
    -module-cache-path "$work/cache" "$root/Shared/FinanceAuthority.swift" \
    "$root/Sources/ResearchFundingModels.swift" "$root/Sources/ResearchFundingImport.swift" \
    "$root/Sources/ResearchFundingStore.swift" "$root/Tests/ResearchFundingRegression.swift" \
    -o "$work/funding-regression"
"$work/funding-regression"
