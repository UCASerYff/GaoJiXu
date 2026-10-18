#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
TEST_DIR=$(mktemp -d /tmp/gaojixu-widget-contract.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/cache" \
    "$ROOT/Sources/WidgetSnapshot.swift" "$ROOT/Tests/WidgetSnapshotRegression.swift" \
    -o "$TEST_DIR/WidgetSnapshotRegression"
"$TEST_DIR/WidgetSnapshotRegression"
