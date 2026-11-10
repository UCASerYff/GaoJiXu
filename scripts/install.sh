#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
TARGET="/Applications/搞积蓄.app"
BUNDLE_ID="com.gaojixu.savings"
WIDGET_ID="com.gaojixu.savings.widgets"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALL_ROOT="$ROOT/.install.noindex"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
PACKAGE="$ROOT/dist/搞积蓄-$VERSION.zip"

function require_main_stopped() {
    if pgrep -f '^/Applications/搞积蓄.app/Contents/MacOS/GaoJiXu' >/dev/null; then
        echo '请先正常退出当前应用；正式安装未改动。' >&2
        return 1
    fi
}

require_main_stopped
[[ -f "$PACKAGE" && -f "$PACKAGE.sha256" ]] || { echo '缺少当前版本发行包或校验文件。' >&2; exit 1; }
(cd "$ROOT/dist" && shasum -a 256 -c "搞积蓄-$VERSION.zip.sha256")
mkdir -p "$INSTALL_ROOT"
touch "$INSTALL_ROOT/.metadata_never_index"
LOCK="$INSTALL_ROOT/installer.lock"
if ! mkdir "$LOCK"; then
    echo '已有安装流程持有锁，请先核对真实进程与路径。' >&2
    exit 1
fi
STAGE=""
SUCCEEDED=0
function finish_install() {
    local result=$?
    trap - EXIT HUP INT TERM
    [[ -z "$STAGE" ]] || rm -rf "$STAGE"
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    if [[ "$SUCCEEDED" != 1 ]]; then
        echo '安装未完成；未创建程序或资料副本，请按上述错误处理。' >&2
    fi
    exit "$result"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
print -r -- "$$" > "$LOCK/pid"
STAGE=$(mktemp -d "$INSTALL_ROOT/install.XXXXXX")
touch "$STAGE/.metadata_never_index"
SOURCE="$STAGE/搞积蓄.app"

ditto -x -k "$PACKAGE" "$STAGE"
codesign --verify --deep --strict "$SOURCE"
[[ "$(codesign -dv "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "5G96498KGJ" ]] || {
    echo '候选程序不是预期团队签名。' >&2
    exit 1
}
python3 -B - "$SOURCE" "$VERSION" "$NUMBER" "$BUNDLE_ID" "$WIDGET_ID" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
version, build, bundle_id, widget_id = sys.argv[2:]
for relative, identifier in (
    ('Contents/Info.plist', bundle_id),
    ('Contents/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist', widget_id),
):
    info = plistlib.loads((app / relative).read_bytes())
    actual = (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion'])
    if actual != (identifier, version, build):
        raise SystemExit(f'候选身份不符：{relative}: {actual}')
PY

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    [[ -f "$TARGET/Contents/Info.plist" ]] || { echo '正式路径存在非预期内容，停止安装。' >&2; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")" == "$BUNDLE_ID" ]] || {
        echo '正式路径 Bundle ID 不符，停止安装。' >&2
        exit 1
    }
    require_main_stopped
    "$LSREGISTER" -u "$TARGET" 2>/dev/null || true
    pluginkit -r "$TARGET/Contents/PlugIns/GaoJiXuWidgets.appex" 2>/dev/null || true
    rm -rf "$TARGET"
fi

ditto "$SOURCE" "$TARGET"
codesign --verify --deep --strict "$TARGET"
diff -r "$SOURCE" "$TARGET" >/dev/null
"$LSREGISTER" -f -R "$TARGET"
pluginkit -a "$TARGET/Contents/PlugIns/GaoJiXuWidgets.appex"
SUCCEEDED=1
echo "Installed $TARGET (V$VERSION build $NUMBER); no backup or recovery copy created."
