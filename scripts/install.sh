#!/bin/zsh
set -euo pipefail
umask 077
ROOT=${0:A:h:h}
TARGET="/Applications/搞积蓄.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WIDGET="Contents/PlugIns/GaoJiXuWidgets.appex"
HELPER="$ROOT/scripts/install_safety.py"
WIDGET_ELECTION_ARGS=()
case "$#" in
    0) ;;
    2) [[ "$1" == '--widget-election' && "$2" == 'use' ]] || { echo '仅支持显式 --widget-election use；默认不改组件选择。' >&2; exit 2; }
       WIDGET_ELECTION_ARGS=(--widget-election use) ;;
    *) echo '用法：install.sh [--widget-election use]' >&2; exit 2 ;;
esac
function require_main_stopped() {
    local query_rc=0
    if pgrep -f '^/Applications/搞积蓄.app/Contents/MacOS/GaoJiXu' >/dev/null; then query_rc=0; else query_rc=$?; fi
    case "$query_rc" in
        1) return 0 ;;
        0) echo '请先正常退出当前应用；原安装保留。' >&2; return 1 ;;
        *) echo "无法确认主程序状态（pgrep=$query_rc）；原安装保留。" >&2; return 1 ;;
    esac
}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
(cd "$ROOT/dist"; shasum -a 256 -c "搞积蓄-$VERSION.zip.sha256")
require_main_stopped
mkdir -p "$ROOT/.install.noindex" "$ROOT/rollback.noindex"
touch "$ROOT/.install.noindex/.metadata_never_index" "$ROOT/rollback.noindex/.metadata_never_index"
LOCK="$ROOT/.install.noindex/installer.lock"
if ! mkdir "$LOCK"; then echo '已有安装或未收尾的安装锁，请核对归属后再继续。' >&2; exit 1; fi
print -r -- "$$" > "$LOCK/pid"
STAGE=""; SAFETY_ROOT=""; SOURCE=""; SAFETY=""; BINDING=""; RECEIPT=""; BASELINE=""
SUCCEEDED=0; HAD_TARGET=0; PROMOTION_STARTED=0
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] || HAD_TARGET=1
function finish_install() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ "$SUCCEEDED" != 1 ]]; then
        if [[ -n "$RECEIPT" && -f "$RECEIPT" && ( -e "$SAFETY" || -L "$SAFETY" || "$PROMOTION_STARTED" == 1 ) ]]; then
            # Remove a retained-path registration only while that exact original still exists.
            # A registry failure must not prevent filesystem recovery; it remains an explicit error.
            if [[ -e "$SAFETY" || -L "$SAFETY" ]]; then
                if python3 -B "$HELPER" verify-original --safety "$SAFETY" --receipt "$RECEIPT"; then
                    "$LSREGISTER" -u "$SAFETY" >> "$SAFETY_ROOT/recovery-registration.log" 2>&1 || result=1
                    pluginkit -r "$SAFETY/$WIDGET" >> "$SAFETY_ROOT/recovery-registration.log" 2>&1 || result=1
                fi
            fi
            if python3 -B "$HELPER" recover --target "$TARGET" --safety "$SAFETY" --binding "$BINDING" --quarantine "$SAFETY_ROOT/failed-new-program.noindex" --receipt "$RECEIPT"; then
                if [[ "$HAD_TARGET" == 1 ]]; then
                    codesign --verify --deep --strict "$TARGET" || result=1
                    "$LSREGISTER" -f -R "$TARGET" || result=1
                    pluginkit -a "$TARGET/$WIDGET" || result=1
                    python3 -B "$HELPER" verify-original --safety "$TARGET" --receipt "$RECEIPT" || result=1
                fi
            else
                echo "恢复身份无法确认，保留正式路径、原件和失败候选：$SAFETY_ROOT" >&2
                result=1
            fi
        fi
        # Interrupted/failed staging and all recovery objects stay in .noindex for inspection.
        [[ -z "$STAGE" ]] || echo "未成功安装；保留本次暂存：$STAGE" >&2
    fi
    if [[ -f "$LOCK/pid" && "$(cat "$LOCK/pid")" == "$$" ]]; then rm "$LOCK/pid"; rmdir "$LOCK" || result=1; fi
    exit "$result"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=$(mktemp -d "$ROOT/.install.noindex/install.XXXXXX")
SAFETY_ROOT=$(mktemp -d "$ROOT/rollback.noindex/recovery.XXXXXX")
echo "本次安装与恢复记录：$SAFETY_ROOT"
mkdir "$SAFETY_ROOT/Program.noindex"
SOURCE="$STAGE/搞积蓄.app"
SAFETY="$SAFETY_ROOT/Program.noindex/搞积蓄.app"
BINDING="$SAFETY_ROOT/new-program-identity.json"
RECEIPT="$SAFETY_ROOT/original-program.json"
BASELINE="$SAFETY_ROOT/registration-baseline.json"
# All enclosing directories are .noindex before any App is extracted or moved.
touch "$STAGE/.metadata_never_index" "$SAFETY_ROOT/.metadata_never_index" "$SAFETY_ROOT/Program.noindex/.metadata_never_index"
ditto -x -k "$ROOT/dist/搞积蓄-$VERSION.zip" "$STAGE"
codesign --verify --deep --strict "$SOURCE"
[[ "$(codesign -dv "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "5G96498KGJ" ]] || { echo '需要原团队开发签名'; exit 1; }
python3 -B - "$SOURCE" "$VERSION" "$NUMBER" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);version,build=sys.argv[2:]
for relative,identifier in [('Contents/Info.plist','com.gaojixu.savings'),('Contents/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist','com.gaojixu.savings.widgets')]:
    info=plistlib.loads((app/relative).read_bytes())
    if (info['CFBundleIdentifier'],info['CFBundleShortVersionString'],info['CFBundleVersion'])!=(identifier,version,build):raise SystemExit('候选ID/版本/构建与本轮不一致')
PY
python3 -B "$HELPER" bind --source "$SOURCE" --binding "$BINDING"
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    HAD_TARGET=1
    codesign --verify --deep --strict "$TARGET"
    # The ZIP is auxiliary, regardless of copy fidelity. It NEVER replaces the same-inode original.
    ditto -c -k --keepParent "$TARGET" "$SAFETY_ROOT/previous-program.zip"
    python3 -B - "$SAFETY_ROOT/previous-program.zip" "$SAFETY_ROOT/auxiliary-archive.json" <<'PY'
import hashlib,json,pathlib,sys,zipfile
archive,out=map(pathlib.Path,sys.argv[1:])
with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None:raise SystemExit('辅助归档损坏，原安装未动')
with out.open('x') as f:
    json.dump({'archive':str(archive),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'auxiliaryOnly':True,'fullMetadataRoundTripClaimed':False,'restoreAuthority':'original-program.json + Program.noindex original inodes; never auto-extract this ZIP to restore'},f,indent=2)
PY
fi
python3 -B "$HELPER" capture-original --target "$TARGET" --safety "$SAFETY" --receipt "$RECEIPT" --binding "$BINDING"
python3 -B "$HELPER" registry-baseline --target "$TARGET" --receipt "$RECEIPT" --baseline "$BASELINE"
require_main_stopped
python3 -B "$HELPER" retain-original --target "$TARGET" --safety "$SAFETY" --receipt "$RECEIPT"
PROMOTION_STARTED=1
python3 -B "$HELPER" promote --source "$SOURCE" --target "$TARGET" --binding "$BINDING"
codesign --verify --deep --strict "$TARGET"
# The registration intent is durable before either command; new installs use the same checks.
python3 -B "$HELPER" register-candidate --receipt "$RECEIPT" --baseline "$BASELINE" "${WIDGET_ELECTION_ARGS[@]}"
codesign --verify --deep --strict "$TARGET"
python3 -B "$HELPER" verify-registered --receipt "$RECEIPT"
python3 -B "$HELPER" clean-stage --binding "$BINDING"
SUCCEEDED=1
echo "Installed $TARGET; authoritative same-inode original and recovery pointer retained: $SAFETY_ROOT"
echo '程序换装不反转金融事务；业务、组件、Spotlight与有效登记唯一性仍由Root核验。'
