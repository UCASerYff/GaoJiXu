"""Run a Windows MSI through its installed entry points using synthetic data."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import msilib
import os
import re
import socket
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid
import winreg
from contextlib import closing, contextmanager
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

WIDGET_TYPES = ("calendar", "net-worth", "expenses", "benefits", "adventure")


def msi_property(package: Path, key: str) -> str:
    database = msilib.OpenDatabase(str(package), msilib.MSIDBOPEN_READONLY)
    view = database.OpenView(f"SELECT `Value` FROM `Property` WHERE `Property` = '{key}'")
    view.Execute(None)
    return view.Fetch().GetString(1)


def verify_shell_entries(package: Path) -> None:
    database = msilib.OpenDatabase(str(package), msilib.MSIDBOPEN_READONLY)
    template = database.GetSummaryInformation(0).GetProperty(7)
    if isinstance(template, bytes):
        template = template.decode("ascii")
    assert template.lower().startswith("x64;")
    view = database.OpenView("SELECT `Target`, `Arguments` FROM `Shortcut`")
    view.Execute(None)
    arguments = []
    while record := view.Fetch():
        assert record.GetString(1) == "[INSTALLFOLDER]GaoJiXu.exe"
        arguments.append(record.GetString(2) or "")
    assert sorted(arguments) == sorted(["", *(f"--widget {widget}" for widget in WIDGET_TYPES)])
    view = database.OpenView("SELECT `Key`, `Value` FROM `Registry` WHERE `Root` = 1")
    view.Execute(None)
    while record := view.Fetch():
        if record.GetString(1) == r"Software\Classes\gaojixu\shell\open\command":
            assert record.GetString(2) == '"[INSTALLFOLDER]GaoJiXu.exe" "%1"'
            return
    raise AssertionError("The MSI does not declare the per-user URI handler")


def msi_exec(root: Path, action: str, target: str, properties: list[str], expected=(0,)) -> None:
    log = root / f"{action.removeprefix('/')}-{uuid.uuid4().hex}.log"
    arguments = subprocess.list2cmdline(
        ["msiexec.exe", action, target, "/qn", "/norestart", "/l*v", str(log)]
    )
    for property_value in properties:
        name, value = property_value.split("=", 1)
        arguments += f' {name}="{value}"'
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = subprocess.SW_HIDE
    for attempt in range(6):
        result = subprocess.run(
            arguments, creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=startup, timeout=120,
        )
        if result.returncode != 1618 or attempt == 5:
            break
        time.sleep(2 + attempt)
    if result.returncode not in expected:
        if log.is_file():
            raw = log.read_bytes()
            encoding = "utf-16" if raw.startswith(b"\xff\xfe") else "mbcs"
            print("\n".join(raw.decode(encoding, errors="replace").splitlines()[-14:]))
        raise RuntimeError(f"Windows Installer {action} failed with exit code {result.returncode}")


def read_registry(key_name: str, name: str = ""):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_name) as key:
            return winreg.QueryValueEx(key, name)[0]
    except FileNotFoundError:
        return None


def ensure_no_installed_version(upgrade_code: str) -> None:
    existing = ctypes.create_unicode_buffer(39)
    code = ctypes.windll.msi.MsiEnumRelatedProductsW(upgrade_code, 0, 0, existing)
    if code != 259:  # ERROR_NO_MORE_ITEMS
        raise RuntimeError(f"Cannot isolate this installation from an existing copy (MSI status {code}).")


def check_x64(executable: Path) -> None:
    with executable.open("rb") as stream:
        assert stream.read(2) == b"MZ", executable
        stream.seek(60)
        pe_offset, = struct.unpack("<I", stream.read(4))
        stream.seek(pe_offset)
        assert stream.read(6) == b"PE\0\0\x64\x86", executable


def legacy_fixture(
    profile: Path, cli: Path, legacy: Path | None, env: dict[str, str], *, old_schema=False,
) -> Path:
    subprocess.run(
        [str(legacy or cli), "--data-dir", str(profile), "--create-empty"],
        env=env, capture_output=True, check=True, timeout=30,
    )
    library = profile / "library.json"
    fixture = json.loads(library.read_text(encoding="utf-8"))
    fixture["installSmokeUnknown"] = {"schema": "existing Windows data"}
    fixture["adventure"]["tickets"] = 37
    library.write_text(json.dumps(fixture, ensure_ascii=False), encoding="utf-8")
    original = library.read_bytes()
    inspected = subprocess.check_output(
        [str(cli), "--data-dir", str(profile), "--inspect"],
        env=env, text=True, timeout=30,
    )
    assert "status=ready" in inspected and original == library.read_bytes()
    if old_schema:
        fixture["version"] = 22
        library.write_text(json.dumps(fixture, ensure_ascii=False), encoding="utf-8")
    return library


@contextmanager
def installed_app(executable: Path, profile: Path, env: dict[str, str]):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    browser = build_opener(ProxyHandler({}))
    origin = f"http://127.0.0.1:{port}"
    process = subprocess.Popen(
        [str(executable), "--data-dir", str(profile), "--serve", "--no-browser", "--port", str(port),
         "--widget", "calendar"],
        env=env, creationflags=subprocess.CREATE_NO_WINDOW,
    )
    headers = {}

    def request(path: str, data: dict | None = None, *, authorized=True) -> bytes:
        encoded = json.dumps(data).encode("utf-8") if data is not None else None
        with browser.open(Request(origin + path, data=encoded, headers=headers if authorized else {}), timeout=4) as response:
            return response.read()

    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"The installed app exited with code {process.returncode}")
            try:
                page = request("/").decode("utf-8")
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The installed app did not start its loopback page.")
                time.sleep(0.25)
        token = re.search(r'name="gao-token" content="([^"]+)"', page)
        assert token is not None
        headers.update({"X-Gao-Token": token.group(1), "Content-Type": "application/json"})
        yield request
    finally:
        if headers:
            try:
                request("/api/shutdown", {})
                process.wait(timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            subprocess.run(
                ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True, timeout=15,
            )
            process.wait(timeout=15)


def exercise_installed_app(
    executable: Path, profile: Path, library: Path, env: dict[str, str], *, existing=False, integration_cli=None,
) -> None:
    with installed_app(executable, profile, env) as request:
        assert request("/assets/mac/GaoJiXuIcon.png").startswith(b"\x89PNG\r\n\x1a\n")
        assert request("/assets/mac/FusionPixel12px.ttf").startswith(b"\x00\x01\x00\x00")
        for widget in WIDGET_TYPES:
            assert b"/assets/widgets.js" in request(f"/?widget={widget}")
        assert b"widget-calendar-grid" in request("/assets/widgets.js")
        assert b"/api/settings/folder" in request("/assets/workbench.js")
        state = json.loads(request("/api/state"))
        if existing:
            assert any(row["note"] == "MSI smoke" for row in state["entries"])
            assert state["settings"]["language"] == "en"
            assert state["monthly"]["preferences"]["timezone"] == "Asia/Shanghai"
            assert any(row["name"] == "MSI test subscription" for row in state["monthly"]["subscriptions"])

        account = state["accounts"][0]["id"]
        note = "MSI smoke after upgrade" if existing else "MSI smoke"
        ledger_entry = {"kind": "expense", "accountID": account, "amount": 3, "categoryID": "food", "note": note}
        assert json.loads(request("/api/ledger/save", ledger_entry))["ok"]
        state = json.loads(request("/api/state"))
        assert any(row["note"] == note for row in state["entries"])
        assert json.loads(request("/api/settings", {"language": "en"}))["ok"]
        if not existing:
            assert json.loads(request("/api/monthly/create", {}))["ok"]
            preferences = json.loads(request("/api/monthly/preferences", {"timezone": "Asia/Shanghai"}))
            assert preferences["result"]["timezone"] == "Asia/Shanghai"
            subscription = {"name": "MSI test subscription", "price": 23, "currency": "CNY", "cycle": "monthly", "interval": 1}
            assert json.loads(request("/api/monthly/subscription", subscription))["ok"]
        assert (profile / "IntegratedFinance" / "Monthly" / "monthly.sqlite").is_file()
        widget = json.loads((profile / "gaojixu-widget.json").read_text(encoding="utf-8"))
        assert widget["schemaVersion"] == 2 and widget["dataRevision"]
        saved = json.loads(library.read_text(encoding="utf-8"))
        assert saved["version"] == 24 and saved["adventure"]["tickets"] == 37
        assert saved["installSmokeUnknown"] == {"schema": "existing Windows data"}
        if integration_cli:
            assert b"/assets/adventure-scene.js" in request("/")
            assert b'getContext("webgl"' in request("/assets/adventure-scene.js")
            assert b"/assets/widgets.css" in request("/?widget=expenses")
            widget_status = json.loads(request("/api/desktop/widgets", {"command": "status"}))
            assert widget_status["result"] == {"available": False, "windows": {}}
            try:
                request("/api/desktop/notification-test", {"language": "en"})
            except HTTPError as exc:
                rejected = json.load(exc)
                assert exc.code == 400 and rejected["code"] == "desktop-notice"
                assert rejected["error"] == "Windows did not accept the notification."
            else:
                raise AssertionError("The app claimed a notification was submitted when no desktop tray was started")
            exercise_monthly_signal(request, profile, integration_cli, env)


def exercise_monthly_signal(request, profile: Path, cli: Path, env: dict[str, str]):
    endpoint = "/api/monthly/integration"
    try:
        request(endpoint, authorized=False)
    except HTTPError as exc:
        assert exc.code == 403
    else:
        raise AssertionError("Monthly integration status requires the application token")
    deadline = time.monotonic() + 8
    settled_since = None
    last_generation = None
    while True:
        before = json.loads(request(endpoint))
        if before["transport"] == "windows-event" and before["source"] == "ready":
            if last_generation != before["generation"]:
                settled_since = time.monotonic()
                last_generation = before["generation"]
            elif time.monotonic() - settled_since >= .4:
                break
        if time.monotonic() >= deadline:
            raise AssertionError(f"Windows event receiver not ready: {before}")
        time.sleep(.1)

    database = profile / "IntegratedFinance" / "Monthly" / "monthly.sqlite"
    with closing(sqlite3.connect(database)) as connection, connection:
        data, = connection.execute("SELECT json FROM state WHERE id = 1").fetchone()
        value = json.loads(data)
        value["subscriptions"][0]["name"] = "MSI synthetic provider revision"
        connection.execute("UPDATE state SET json = ? WHERE id = 1", (json.dumps(value).encode("utf-8"),))
    signal = subprocess.check_output(
        [str(cli), "--data-dir", str(profile), "--notify-monthly-change"], env=env, text=True, timeout=15,
    )
    assert signal.strip() == "monthly-change-signaled"
    deadline = time.monotonic() + 6
    while True:
        after = json.loads(request(endpoint))
        if after["source"] == "ready" and after["generation"] > before["generation"]:
            assert after["transport"] == "windows-event"
            assert after["externalProvider"] == "unverified"
            state = json.loads(request("/api/state"))
            assert any(row["name"] == "MSI synthetic provider revision" for row in state["monthly"]["subscriptions"])
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f"Monthly synthetic producer signal did not refresh the installed app: {after}")
        time.sleep(.1)


def data_manifest(directory: Path) -> dict[Path, bytes]:
    result = {}
    for path in directory.rglob("*"):
        if path.is_file():
            with path.open("rb") as stream:
                result[path.relative_to(directory)] = hashlib.file_digest(stream, "sha256").digest()
    return result


def exercise_protected_library(executable: Path, profile: Path, env: dict[str, str]) -> None:
    profile.mkdir()
    library = profile / "library.json"
    original = b'{"version": 777}'
    library.write_bytes(original)
    with installed_app(executable, profile, env) as request:
        assert json.loads(request("/api/state"))["status"] == "protected"
        try:
            request("/api/library/create", {})
        except HTTPError as exc:
            assert exc.code == 400 and json.load(exc)["code"] == "protected"
        else:
            raise AssertionError("Installed application accepted a write to an unsupported library")
        assert library.read_bytes() == original


def verify_checksum(package: Path) -> None:
    sidecar = package.with_suffix(".msi.sha256").read_text(encoding="ascii").strip()
    with package.open("rb") as stream:
        assert sidecar == f"{hashlib.file_digest(stream, 'sha256').hexdigest()}  {package.name}"


def smoke(package: Path, legacy: Path | None, register_shell: bool, upgrade_from: Path | None) -> None:
    verify_checksum(package)
    verify_shell_entries(package)
    product_code = msi_property(package, "ProductCode")
    product_version = msi_property(package, "ProductVersion")
    version = "+".join(product_version.rsplit(".", 1))
    supports_integration = tuple(map(int, product_version.split("."))) >= (4, 6, 3)
    upgrade_code = msi_property(package, "UpgradeCode")
    ensure_no_installed_version(upgrade_code)
    previous_code = None
    if upgrade_from:
        verify_checksum(upgrade_from)
        assert msi_property(upgrade_from, "UpgradeCode") == upgrade_code
        previous_code = msi_property(upgrade_from, "ProductCode")
        assert previous_code != product_code
    protocol_key = r"Software\Classes\gaojixu"
    menu = Path(os.environ["APPDATA"]) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "搞积蓄"
    if register_shell and (read_registry(protocol_key, "URL Protocol") is not None or menu.exists()):
        raise RuntimeError("The current Windows account already has GaoJiXu Shell integration.")
    with tempfile.TemporaryDirectory(prefix="GaoJiXu-install-") as isolated:
        root = Path(isolated)
        install = root / "安装 # Windows"
        profile = root / "旧版 # 资料"
        test_key = rf"Software\GaoSeries\GaoJiXu.InstallSmoke.{uuid.uuid4().hex}"
        properties = [f"INSTALLFOLDER={install}", f"GAOJIXU_STATE_KEY={test_key}"]
        if not register_shell:
            properties.append("GAOJIXU_TEST_INSTALL=1")
        runtime = root / "runtime"
        runtime.mkdir()
        env = dict(
            os.environ, GAOJIXU_DATA_DIR=str(profile), GAOJIXU_NO_BATTLE="1",
            TEMP=str(runtime), TMP=str(runtime),
        )
        app = install / "GaoJiXu.exe"
        cli = install / "GaoJiXu-cli.exe"
        library = None
        try:
            if upgrade_from:
                msi_exec(root, "/i", str(upgrade_from), properties)
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == 5
                assert not profile.exists()
                library = legacy_fixture(profile, cli, None, env)
                exercise_installed_app(app, profile, library, env)
                original = data_manifest(profile)
            msi_exec(root, "/i", str(package), properties)
            if upgrade_from:
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == -1
                assert data_manifest(profile) == original
            check_x64(app)
            check_x64(cli)
            assert Path(read_registry(test_key, "InstallPath")) == install
            if register_shell:
                assert read_registry(protocol_key + r"\shell\open\command") == f'"{app}" "%1"'
                assert len(list(menu.glob("*.lnk"))) == 6
            assert subprocess.check_output([str(cli), "--version"], env=env, text=True, timeout=30).strip() == version
            if library is None:
                assert not profile.exists()
                library = legacy_fixture(profile, cli, legacy, env, old_schema=True)
            integration_cli = cli if supports_integration else None
            exercise_installed_app(app, profile, library, env, existing=bool(upgrade_from), integration_cli=integration_cli)
            exercise_protected_library(app, root / "只读验证", env)
            data_hashes = data_manifest(profile)
            if upgrade_from:
                msi_exec(root, "/i", str(upgrade_from), properties, expected=(1603, 1638))
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == -1
                assert ctypes.windll.msi.MsiQueryProductStateW(product_code) == 5
                assert subprocess.check_output([str(cli), "--version"], env=env, text=True, timeout=30).strip() == version
                assert data_manifest(profile) == data_hashes
        finally:
            for installed_code in (product_code, previous_code):
                if installed_code and ctypes.windll.msi.MsiQueryProductStateW(installed_code) == 5:
                    msi_exec(root, "/x", installed_code, properties)
            assert read_registry(test_key, "InstallPath") is None
            try:
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, test_key)
            except FileNotFoundError:
                pass
        assert not app.exists() and not cli.exists()
        assert data_manifest(profile) == data_hashes
        if register_shell:
            assert read_registry(protocol_key, "URL Protocol") is None and not menu.exists()
    print("MSI smoke passed: installation, x64 app and CLI, assets, protected data, ledger, monthly SQLite, widgets, uninstall")
    if upgrade_from:
        print("MSI upgrade passed: previous product replaced, downgrade blocked, previous data and settings preserved")
    else:
        print("MSI migration passed: isolated schema 22 library migrated to schema 24")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--legacy-cli", type=Path)
    parser.add_argument("--upgrade-from", type=Path, help="Optional already-built older MSI for an isolated upgrade test.")
    parser.add_argument("--register-shell", action="store_true", help="Use only with a disposable Windows account.")
    args = parser.parse_args()
    smoke(args.package.resolve(strict=True), args.legacy_cli, args.register_shell, args.upgrade_from)
