#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
TARGET="/Applications/搞积蓄.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
WIDGET="Contents/PlugIns/GaoJiXuWidgets.appex"
function require_main_stopped() {
    local query_rc=0
    if pgrep -f '^/Applications/搞积蓄.app/Contents/MacOS/GaoJiXu' >/dev/null; then
        query_rc=0
    else
        query_rc=$?
    fi
    case "$query_rc" in
        1) return 0 ;;
        0) echo '请先正常退出当前应用；原安装保留。' >&2; return 1 ;;
        *) echo "无法确认主程序状态（pgrep=$query_rc）；原安装保留。" >&2; return 1 ;;
    esac
}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Info.plist")
# Install exactly the published candidate, including its sanitized executable and signature.
(cd "$ROOT/dist"; shasum -a 256 -c "搞积蓄-$VERSION.zip.sha256")
require_main_stopped
mkdir -p "$ROOT/.install.noindex" "$ROOT/rollback.noindex"
touch "$ROOT/.install.noindex/.metadata_never_index" "$ROOT/rollback.noindex/.metadata_never_index"
LOCK="$ROOT/.install.noindex/installer.lock"
if ! mkdir "$LOCK"; then echo '已有安装或未收尾的安装锁，请核对归属后再继续。' >&2; exit 1; fi
print -r -- "$$" > "$LOCK/pid"
STAGE=""
SAFETY_ROOT=""
SOURCE=""
SAFETY=""
ARCHIVE=""
BINDING=""
SUCCEEDED=0
HAD_TARGET=0
PROMOTION_STARTED=0
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] || HAD_TARGET=1
function finish_install() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ "$SUCCEEDED" != 1 ]]; then
        # Inspect the exact safety path too: a signal can occur between mv and a flag assignment.
        if [[ -e "$SAFETY" || -L "$SAFETY" || ( "$HAD_TARGET" == 0 && "$PROMOTION_STARTED" == 1 ) ]]; then
            if python3 "$ROOT/scripts/install_safety.py" recover --target "$TARGET" --safety "$SAFETY" --binding "$BINDING" --quarantine "$SAFETY_ROOT/failed-new-program.noindex"; then
                if [[ "$HAD_TARGET" == 1 ]]; then
                    "$LSREGISTER" -f -R "$TARGET" || result=1
                    pluginkit -a "$TARGET/$WIDGET" || result=1
                fi
            else
                echo "正式路径归属无法确认，未删除其内容；保留原程序和恢复资料于 $SAFETY_ROOT。" >&2
                result=1
            fi
        fi
    fi
    [[ -z "$STAGE" ]] || rm -rf "$STAGE"
    if [[ -f "$LOCK/pid" && "$(cat "$LOCK/pid")" == "$$" ]]; then
        rm "$LOCK/pid"
        rmdir "$LOCK" || result=1
    fi
    exit "$result"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=$(mktemp -d "$ROOT/.install.noindex/install.XXXXXX")
SAFETY_ROOT=$(mktemp -d "$ROOT/rollback.noindex/recovery.XXXXXX")
SOURCE="$STAGE/搞积蓄.app"
SAFETY="$SAFETY_ROOT/搞积蓄.app"
ARCHIVE="$SAFETY_ROOT/previous-program.zip"
BINDING="$SAFETY_ROOT/new-program-identity.json"
python3 - "$TARGET" "$SAFETY_ROOT" <<'PY'
import pathlib,plistlib,sys
app,recovery=map(pathlib.Path,sys.argv[1:])
if app.is_symlink():raise SystemExit('正式安装路径是符号链接，保留原物不替换')
if app.exists():
    if not app.is_dir():raise SystemExit('正式路径不是应用目录，保留原物')
    for rel,bundle in [('Contents/Info.plist','com.gaojixu.savings'),('Contents/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist','com.gaojixu.savings.widgets')]:
        if plistlib.loads((app/rel).read_bytes()).get('CFBundleIdentifier')!=bundle:
            raise SystemExit('正式路径被其他应用占用，保留原物')
    if app.stat().st_dev!=recovery.stat().st_dev:raise SystemExit('回滚容器不在同一卷，拒绝非原子替换')
PY
# Before the first .app is extracted, every ancestor staging container is already non-indexable.
touch "$STAGE/.metadata_never_index" "$SAFETY_ROOT/.metadata_never_index"
ditto -x -k "$ROOT/dist/搞积蓄-$VERSION.zip" "$STAGE"
codesign --verify --deep --strict "$SOURCE"
[[ "$(codesign -dv "$SOURCE" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "5G96498KGJ" ]] || { echo '需要团队签名'; exit 1; }
python3 - "$SOURCE" "$VERSION" "$NUMBER" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]); version,build=sys.argv[2:]
for relative,identifier in [('Contents/Info.plist','com.gaojixu.savings'),('Contents/PlugIns/GaoJiXuWidgets.appex/Contents/Info.plist','com.gaojixu.savings.widgets')]:
    info=plistlib.loads((app/relative).read_bytes())
    if (info['CFBundleIdentifier'],info['CFBundleShortVersionString'],info['CFBundleVersion'])!=(identifier,version,build):
        raise SystemExit('安装候选的ID/版本/构建与源码不一致，原程序未动')
PY
python3 "$ROOT/scripts/install_safety.py" bind --source "$SOURCE" --binding "$BINDING"
if [[ -d "$TARGET" ]]; then
    HAD_TARGET=1
    codesign --verify --deep --strict "$TARGET"
    ditto -c -k --keepParent "$TARGET" "$ARCHIVE"
    mkdir -p "$SAFETY_ROOT/archive-check.noindex"
    ditto -x -k "$ARCHIVE" "$SAFETY_ROOT/archive-check.noindex"
    codesign --verify --deep --strict "$SAFETY_ROOT/archive-check.noindex/搞积蓄.app"
    python3 - "$TARGET" "$SAFETY_ROOT/archive-check.noindex/搞积蓄.app" "$ARCHIVE" "$SAFETY_ROOT/receipt.json" <<'PY'
import hashlib,json,pathlib,plistlib,sys
original,restored,archive,receipt=map(pathlib.Path,sys.argv[1:])
def manifest(root):
    result={}
    for p in root.rglob('*'):
        if p.is_symlink():result[str(p.relative_to(root))]={'symlink':str(p.readlink())}
        elif p.is_file():result[str(p.relative_to(root))]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
    return result
files=manifest(original)
if files!=manifest(restored):raise SystemExit('Archive round-trip mismatch; original installation preserved')
info=plistlib.loads((original/'Contents/Info.plist').read_bytes())
receipt.write_text(json.dumps({'archive':str(archive),'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bundleID':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'formalPath':str(original),'roundTripVerified':True,'files':files,'restore':'verify archive SHA; extract only inside .noindex, verify manifest and codesign, then replace formal app after normal exit; never overwrite user data'},ensure_ascii=False,indent=2))
PY
    rm -rf "$SAFETY_ROOT/archive-check.noindex"
    # Do not unregister an old program that is still at its formal path. Replacement is followed
    # by exact registration; EXIT/signal handlers restore the old program on any failed step.
    require_main_stopped
    mv "$TARGET" "$SAFETY"
fi
PROMOTION_STARTED=1
python3 "$ROOT/scripts/install_safety.py" promote --source "$SOURCE" --target "$TARGET" --binding "$BINDING"
codesign --verify --deep --strict "$TARGET"
"$LSREGISTER" -f -R "$TARGET"
pluginkit -a "$TARGET/$WIDGET"
SUCCEEDED=1
killall -TERM GaoJiXuWidgets 2>/dev/null || true
# Recovery is retained as a verified ZIP, never a searchable expanded old application.
[[ ! -d "$SAFETY" ]] || rm -rf "$SAFETY"
echo "Installed $TARGET; verified recovery archive: $SAFETY_ROOT"
echo '业务与小组件验收、当前用户会话的安装入口唯一性仍须核验。'
