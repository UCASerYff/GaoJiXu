"""Run a Windows MSI through its installed entry points using synthetic data."""

from __future__ import annotations

import argparse
import csv
import ctypes
import hashlib
import json
import msilib
import os
import re
import shutil
import socket
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid
import winreg
from contextlib import closing, contextmanager
from io import StringIO
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

WIDGET_TYPES = ("calendar", "net-worth", "expenses", "benefits", "adventure")
APP_REGISTRY = r"Software\GaoSeries\GaoJiXu"
PROTOCOL_REGISTRY = r"Software\Classes\gaojixu"
SHELL_COMPONENTS = {"GaoJiXuProtocol", "GaoJiXuShortcuts"}

if not __debug__:
    raise RuntimeError("The installer smoke test must run with Python assertions enabled.")

def msi_property(package: Path, key: str) -> str:
    database = msilib.OpenDatabase(str(package), msilib.MSIDBOPEN_READONLY)
    try:
        record, = msi_records(database, f"SELECT `Value` FROM `Property` WHERE `Property` = '{key}'")
        return record.GetString(1)
    finally:
        database.Close()


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


def msi_records(database, sql):
    view = database.OpenView(sql)
    try:
        view.Execute(None)
        records = []
        while record := view.Fetch():
            records.append(record)
        return records
    finally:
        view.Close()


def msi_execute(database, sql, record=None) -> None:
    view = database.OpenView(sql)
    try:
        view.Execute(record)
    finally:
        view.Close()


def msi_guid(identifier: uuid.UUID) -> str:
    return "{" + str(identifier).upper() + "}"


def sandbox_properties(install: Path, state_key: str) -> dict[str, str]:
    return {"INSTALLFOLDER": str(install), "GAOJIXU_STATE_KEY": state_key, "GAOJIXU_TEST_INSTALL": "1"}


def isolated_directory_name(namespace: uuid.UUID) -> str:
    return f"GJ{namespace.hex[:6].upper()}|GaoJiXu-QA-{namespace.hex}"


def update_identity(reference: Path, namespace: uuid.UUID, family: str, install: Path, state_key: str) -> str:
    # Both versions use the same mapping so related-product and component behavior is preserved.
    original_family = msi_property(reference, "UpgradeCode")
    original_code = msi_property(reference, "ProductCode")
    assert msi_property(reference, "GAOJIXU_STATE_KEY") == APP_REGISTRY
    database = msilib.OpenDatabase(str(reference), msilib.MSIDBOPEN_TRANSACT)
    try:
        property_view = database.OpenView("SELECT `Property`, `Value` FROM `Property`")
        product = msi_guid(uuid.uuid5(namespace, original_code.lower()))
        values = {"ProductCode": product, "UpgradeCode": family, **sandbox_properties(install, state_key)}
        property_view.Execute(None)
        while record := property_view.Fetch():
            key = record.GetString(1)
            if key in values:
                record.SetString(2, values.pop(key))
                property_view.Modify(msilib.MSIMODIFY_UPDATE, record)
        property_view.Close()
        for key, value in values.items():
            record = msilib.CreateRecord(2)
            record.SetString(1, key)
            record.SetString(2, value)
            msi_execute(database, "INSERT INTO `Property` (`Property`, `Value`) VALUES (?, ?)", record)

        rows = msi_records(database, "SELECT * FROM `Upgrade`")
        assert len(rows) == 2 and all(row.GetString(1) == original_family for row in rows)
        msi_execute(database, "DELETE FROM `Upgrade`")
        for row in rows:
            row.SetString(1, family)
            msi_execute(database, "INSERT INTO `Upgrade` (`UpgradeCode`, `VersionMin`, `VersionMax`, "
                "`Language`, `Attributes`, `Remove`, `ActionProperty`) VALUES (?, ?, ?, ?, ?, ?, ?)", row)

        component_view = database.OpenView("SELECT `Component`, `ComponentId`, `Condition` FROM `Component`")
        component_view.Execute(None)
        components = set()
        while record := component_view.Fetch():
            component = record.GetString(1)
            components.add(component)
            if component in SHELL_COMPONENTS:
                assert record.GetString(3) == "NOT GAOJIXU_TEST_INSTALL"
                record.SetString(3, "0")
            record.SetString(2, msi_guid(uuid.uuid5(namespace, record.GetString(2).lower())))
            component_view.Modify(msilib.MSIMODIFY_UPDATE, record)
        component_view.Close()
        assert components == {"GaoJiXuAppFiles", *SHELL_COMPONENTS}

        # RemoveExistingProducts can run the prior package without the parent's command-line properties.
        # Give cached transforms concrete registry and directory names as well as safe property defaults.
        registry_view = database.OpenView("SELECT `Registry`, `Root`, `Key`, `Component_` FROM `Registry`")
        registry_view.Execute(None)
        while record := registry_view.Fetch():
            assert record.GetInteger(2) == 1
            key, component = record.GetString(3), record.GetString(4)
            if component == "GaoJiXuAppFiles":
                assert key == "[GAOJIXU_STATE_KEY]"
                path = state_key
            elif component == "GaoJiXuProtocol":
                assert key.startswith(PROTOCOL_REGISTRY)
                path = state_key + r"\SuppressedProtocol" + key[len(PROTOCOL_REGISTRY):]
            else:
                assert component == "GaoJiXuShortcuts" and key == APP_REGISTRY
                path = state_key + r"\SuppressedShortcuts"
            record.SetString(3, path)
            registry_view.Modify(msilib.MSIMODIFY_UPDATE, record)
        registry_view.Close()
        directory_view = database.OpenView("SELECT `Directory`, `DefaultDir` FROM `Directory`")
        directory_view.Execute(None)
        directories = set()
        while record := directory_view.Fetch():
            directory = record.GetString(1)
            if directory in {"INSTALLFOLDER", "GaoJiXuMenuFolder"}:
                record.SetString(2, isolated_directory_name(namespace))
                directory_view.Modify(msilib.MSIMODIFY_UPDATE, record)
                directories.add(directory)
        directory_view.Close()
        assert directories == {"INSTALLFOLDER", "GaoJiXuMenuFolder"}
        database.Commit()
        return product
    finally:
        database.Close()


@contextmanager
def native_msi_database(path: Path, *, writable=False):
    dll = ctypes.windll.msi
    handle = ctypes.c_uint()
    mode = ctypes.c_void_p(1 if writable else 0)
    open_database = dll.MsiOpenDatabaseW
    open_database.argtypes = (ctypes.c_wchar_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint))
    result = open_database(str(path), mode, ctypes.byref(handle))
    if result:
        raise OSError(f"Opening an MSI for the isolated test failed with Windows Installer status {result}.")
    try:
        yield handle
    finally:
        dll.MsiCloseHandle(handle)


def isolated_transform(
    package: Path, root: Path, namespace: uuid.UUID, family: str, install: Path, state_key: str,
) -> tuple[str, str]:
    reference = root / f"identity-{msi_property(package, 'ProductVersion')}.msi"
    transform = reference.with_suffix(".mst")
    dll = ctypes.windll.msi
    shutil.copyfile(package, reference)
    code = update_identity(reference, namespace, family, install, state_key)
    with native_msi_database(package) as original, native_msi_database(reference) as isolated:
        result = dll.MsiDatabaseGenerateTransformW(isolated, original, str(transform), 0, 0)
        if not result:
            result = dll.MsiCreateTransformSummaryInfoW(isolated, original, str(transform), 0, 0)
        if result:
            raise OSError(f"Creating the isolated MSI transform failed with Windows Installer status {result}.")

    # Check the actual transform against a fresh copy before starting Windows Installer.
    shutil.copyfile(package, reference)
    with native_msi_database(reference, writable=True) as check:
        result = dll.MsiDatabaseApplyTransformW(check, str(transform), 0)
        if not result:
            result = dll.MsiDatabaseCommit(check)
        if result:
            raise OSError(f"Checking the isolated MSI transform failed with Windows Installer status {result}.")
    assert msi_property(reference, "ProductCode") == code
    assert msi_property(reference, "ProductVersion") == msi_property(package, "ProductVersion")
    assert msi_property(reference, "UpgradeCode") == family
    for key, value in sandbox_properties(install, state_key).items():
        assert msi_property(reference, key) == value
    original = msilib.OpenDatabase(str(package), msilib.MSIDBOPEN_READONLY)
    isolated = msilib.OpenDatabase(str(reference), msilib.MSIDBOPEN_READONLY)
    try:
        transformed_rows = msi_records(isolated, "SELECT `Component`, `ComponentId`, `Condition` FROM `Component`")
        actual = {row.GetString(1): row.GetString(2) for row in transformed_rows}
        expected = {
            row.GetString(1): msi_guid(uuid.uuid5(namespace, row.GetString(2).lower()))
            for row in msi_records(original, "SELECT `Component`, `ComponentId` FROM `Component`")
        }
        assert actual == expected
        assert all(row.GetString(3) == "0" for row in transformed_rows if row.GetString(1) in SHELL_COMPONENTS)
        assert all(row.GetString(1) == family for row in msi_records(isolated, "SELECT `UpgradeCode` FROM `Upgrade`"))
        for row in msi_records(isolated, "SELECT `Root`, `Key`, `Component_` FROM `Registry`"):
            assert row.GetInteger(1) == 1
            key = row.GetString(2)
            if row.GetString(3) == "GaoJiXuAppFiles":
                assert key == state_key
            else:
                assert key.startswith(state_key + "\\")
        directory_rows = msi_records(isolated, "SELECT `Directory`, `DefaultDir` FROM `Directory`")
        assert all(row.GetString(2) == isolated_directory_name(namespace) for row in directory_rows
                   if row.GetString(1) in {"INSTALLFOLDER", "GaoJiXuMenuFolder"})
    finally:
        original.Close()
        isolated.Close()
    reference.unlink()
    return code, str(transform)


def msi_exec(root: Path, action: str, target: str, properties: list[str], expected=(0,), *, log_marker=None) -> None:
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
    for attempt in range(16):
        result = subprocess.run(
            arguments, creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=startup, timeout=120,
        )
        if result.returncode != 1618 or attempt == 15:
            break
        time.sleep(min(2 + attempt, 6))
    if result.returncode in expected and log_marker is None:
        return
    raw = log.read_bytes() if log.is_file() else b""
    encoding = "utf-16" if raw.startswith(b"\xff\xfe") else "mbcs"
    output = raw.decode(encoding, errors="replace")
    if result.returncode in expected and log_marker in output:
        return
    print("\n".join(output.splitlines()[-14:]))
    raise RuntimeError(f"Windows Installer {action} did not produce the expected result (status {result.returncode}).")


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


def installed_family(upgrade_code: str) -> dict[str, int]:
    products = {}
    index = 0
    while True:
        code = ctypes.create_unicode_buffer(39)
        result = ctypes.windll.msi.MsiEnumRelatedProductsW(upgrade_code, 0, index, code)
        if result == 259:
            return products
        if result:
            raise RuntimeError(f"Cannot inspect the registered GaoJiXu product family (MSI status {result}).")
        products[code.value] = ctypes.windll.msi.MsiQueryProductStateW(code.value)
        index += 1


class ProductionScopeChanged(RuntimeError):
    pass


@contextmanager
def test_workspace():
    temp = Path(tempfile.gettempdir()).resolve()
    path = Path(tempfile.mkdtemp(prefix="GaoJiXu-install-", dir=temp)).resolve()
    assert path.parent == temp and path.name.startswith("GaoJiXu-install-")
    retain = False
    try:
        yield path
    except ProductionScopeChanged:
        retain = True
        print(f"Retained test workspace after a production scope change: {path}")
        raise
    finally:
        if not retain:
            shutil.rmtree(path)


def production_scope(upgrade_code: str, menu: Path) -> dict:
    snapshot = {f"MSI product {code}": status for code, status in installed_family(upgrade_code).items()}
    for key, name in ((APP_REGISTRY, "InstallPath"), (APP_REGISTRY, "Shortcuts"),
                      (PROTOCOL_REGISTRY + r"\shell\open\command", "")):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as handle:
                value = winreg.QueryValueEx(handle, name)
        except FileNotFoundError:
            value = None
        snapshot[f"HKCU\\{key} [{name or '(Default)'}]"] = value
    for path, digest in data_manifest(menu).items():
        snapshot[f"Shortcut {path}"] = digest.hex()
    return snapshot


def verify_production_scope(upgrade_code: str, menu: Path, before: dict) -> None:
    after = production_scope(upgrade_code, menu)
    missing = "<not present>"
    difference = [
        f"{key}: previous {before.get(key, missing)!r}, current {after.get(key, missing)!r}"
        for key in sorted(before.keys() | after.keys()) if before.get(key, missing) != after.get(key, missing)
    ]
    if difference:
        raise ProductionScopeChanged("A production installation record changed during the isolated test.\n"
                                     + "\n".join(difference))


def verify_registered_transform(product: str, transform: str) -> None:
    path = ctypes.create_unicode_buffer(32768)
    size = ctypes.c_uint(len(path))
    status = ctypes.windll.msi.MsiGetProductInfoW(product, "Transforms", path, ctypes.byref(size))
    assert status == 0, f"Cannot read the isolated instance transform registration (MSI status {status})."
    assert Path(path.value).name.lower() == Path(transform).name.lower(), "Wrong transform registered for test instance."


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
    profile_key = hashlib.sha256(os.path.normcase(str(profile.resolve())).encode("utf-8")).hexdigest().encode("ascii")
    process = subprocess.Popen(
        [str(executable), "--data-dir", str(profile), "--serve", "--no-browser", "--port", str(port),
         "--widget", "calendar"],
        env=env, creationflags=subprocess.CREATE_NO_WINDOW,
    )
    headers = {}

    def assert_profile() -> None:
        with browser.open(origin + "/instance", timeout=4) as response:
            if response.read(128) != profile_key:
                raise RuntimeError("The installer smoke app did not identify its isolated profile.")

    def request(path: str, data: dict | None = None, *, authorized=True) -> bytes:
        if data is not None:
            assert_profile()
        encoded = json.dumps(data).encode("utf-8") if data is not None else None
        with browser.open(Request(origin + path, data=encoded, headers=headers if authorized else {}), timeout=4) as response:
            return response.read()

    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"The installed app exited with code {process.returncode}")
            try:
                assert_profile()
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
    redesigned=False,
) -> None:
    with installed_app(executable, profile, env) as request:
        page = request("/")
        for asset in set(re.findall(rb'(?:href|src)="(/assets/[^"]+)"', page)):
            assert request(asset.decode("ascii")), asset
        if redesigned:
            assert all(marker in page for marker in (b'"/assets/fixed.css"', b'id="app-frame"', b'class="nav-rail"'))
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


def exercise_csv_review(executable: Path, profile: Path, env: dict[str, str]) -> None:
    endpoint = "/api/csv/review"
    note = "MSI synthetic CSV review"
    with installed_app(executable, profile, env) as request:
        state = json.loads(request("/api/state"))
        account = next(row for row in state["accounts"] if row["currency"] == "CNY")
        source = StringIO()
        csv.writer(source, lineterminator="\n").writerows([
            ["日期", "类型", "账户", "目标账户", "分类", "备注", "金额", "币种"],
            ["2026-10-03T12:30:00+08:00", "支出", account["name"], "", "餐饮", note, "18.75", "CNY"],
        ])
        staged = json.loads(request(endpoint + "/stage", {"text": source.getvalue(), "name": "synthetic.csv"}))
        assert staged["ok"] and len(staged["result"]["rows"]) == 1
        batch_id = staged["result"]["batch"]["id"]
        assert staged["result"]["batch"]["status"] == "pending"
        row_id = staged["result"]["rows"][0]["id"]
        assert not any(row["note"] == note for row in json.loads(request("/api/state"))["entries"])

    with installed_app(executable, profile, env) as request:
        review = json.loads(request(endpoint + "/detail?batchID=" + batch_id))
        assert review["batch"]["id"] == batch_id and review["rows"][0]["id"] == row_id
        assert review["batch"]["status"] == "pending" and review["rows"][0]["canApply"]
        assert not any(row["note"] == note for row in json.loads(request("/api/state"))["entries"])
        command = {"batchID": batch_id, "revision": review["batch"]["revision"], "decisions": {row_id: "apply"},
                   "pairs": [], "overrideDuplicates": [], "confirmed": True}
        saved = json.loads(request(endpoint + "/apply", command))
        repeated = json.loads(request(endpoint + "/apply", command))
        assert saved["ok"] and repeated["ok"]
        assert saved["result"]["batch"]["status"] == "applied"
        assert repeated["result"]["rows"][0]["entryID"] == saved["result"]["rows"][0]["entryID"]
        entries = [row for row in json.loads(request("/api/state"))["entries"] if row["note"] == note]
        entry, = entries
        assert entry["accountID"] == account["id"] and entry["amount"] == 18.75
    print("MSI CSV review passed: draft survived restart and repeated confirmation wrote one entry")


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


def smoke(package: Path, legacy: Path | None, register_shell: bool, upgrade_from: Path | None, isolate_identities=False) -> None:
    verify_checksum(package)
    verify_shell_entries(package)
    product_code = msi_property(package, "ProductCode")
    product_version = msi_property(package, "ProductVersion")
    version = "+".join(product_version.rsplit(".", 1))
    version_parts = tuple(map(int, product_version.split(".")))
    supports_integration = version_parts >= (4, 6, 3)
    redesigned = version_parts >= (4, 6, 4)
    reviews_csv = version_parts >= (4, 6, 6)
    upgrade_code = msi_property(package, "UpgradeCode")
    if isolate_identities and register_shell:
        raise ValueError("An isolated MSI test may not register the production Shell entries.")
    if not isolate_identities:
        ensure_no_installed_version(upgrade_code)
    previous_code = None
    if upgrade_from:
        verify_checksum(upgrade_from)
        verify_shell_entries(upgrade_from)
        assert msi_property(upgrade_from, "UpgradeCode") == upgrade_code
        previous_code = msi_property(upgrade_from, "ProductCode")
        assert previous_code != product_code
    protocol_key = PROTOCOL_REGISTRY
    menu = Path(os.environ["APPDATA"]) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "搞积蓄"
    if register_shell and (read_registry(protocol_key, "URL Protocol") is not None or menu.exists()):
        raise RuntimeError("The current Windows account already has GaoJiXu Shell integration.")
    with test_workspace() as root:
        install = root / "安装 # Windows"
        profile = root / "旧版 # 资料"
        test_key = rf"Software\GaoSeries\GaoJiXu.InstallSmoke.{uuid.uuid4().hex}"
        properties = [f"INSTALLFOLDER={install}", f"GAOJIXU_STATE_KEY={test_key}"]
        if not register_shell:
            properties.append("GAOJIXU_TEST_INSTALL=1")
        current_instance = previous_instance = []
        current_transform = previous_transform = None
        if isolate_identities:
            namespace = uuid.uuid4()
            test_family = msi_guid(namespace)
            production_before = production_scope(upgrade_code, menu)
            ensure_no_installed_version(test_family)
            product_code, current_transform = isolated_transform(package, root, namespace, test_family, install, test_key)
            current_instance = ["MSINEWINSTANCE=1", "TRANSFORMSSECURE=1", f"TRANSFORMS={current_transform}"]
            if upgrade_from:
                previous_code, previous_transform = isolated_transform(upgrade_from, root, namespace, test_family, install, test_key)
                previous_instance = ["MSINEWINSTANCE=1", "TRANSFORMSSECURE=1", f"TRANSFORMS={previous_transform}"]
            for code in (product_code, previous_code):
                if code:
                    assert ctypes.windll.msi.MsiQueryProductStateW(code) == -1
            properties = []

        def run_msi(action, target, arguments, **expectation):
            if isolate_identities:
                verify_production_scope(upgrade_code, menu, production_before)
            try:
                msi_exec(root, action, target, arguments, **expectation)
            finally:
                if isolate_identities:
                    verify_production_scope(upgrade_code, menu, production_before)

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
                run_msi("/i", str(upgrade_from), properties + previous_instance)
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == 5
                if previous_transform:
                    verify_registered_transform(previous_code, previous_transform)
                assert not profile.exists()
                library = legacy_fixture(profile, cli, None, env)
                exercise_installed_app(app, profile, library, env)
                original = data_manifest(profile)
            run_msi("/i", str(package), properties + current_instance)
            if current_transform:
                verify_registered_transform(product_code, current_transform)
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
            exercise_installed_app(app, profile, library, env, existing=bool(upgrade_from),
                                   integration_cli=integration_cli, redesigned=redesigned)
            if reviews_csv:
                exercise_csv_review(app, profile, env)
            exercise_protected_library(app, root / "只读验证", env)
            data_hashes = data_manifest(profile)
            if upgrade_from:
                run_msi("/i", str(upgrade_from), properties + previous_instance, expected=(1603, 1638),
                        log_marker="Adding WIX_DOWNGRADE_DETECTED property")
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == -1
                assert ctypes.windll.msi.MsiQueryProductStateW(product_code) == 5
                assert subprocess.check_output([str(cli), "--version"], env=env, text=True, timeout=30).strip() == version
                assert data_manifest(profile) == data_hashes
        finally:
            if isolate_identities:
                verify_production_scope(upgrade_code, menu, production_before)
            for installed_code in (product_code, previous_code):
                if installed_code and ctypes.windll.msi.MsiQueryProductStateW(installed_code) == 5:
                    run_msi("/x", installed_code, properties)
            assert read_registry(test_key, "InstallPath") is None
            try:
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, test_key)
            except FileNotFoundError:
                pass
            if isolate_identities:
                assert not installed_family(test_family)
                verify_production_scope(upgrade_code, menu, production_before)
        assert not app.exists() and not cli.exists()
        assert data_manifest(profile) == data_hashes
        if register_shell:
            assert read_registry(protocol_key, "URL Protocol") is None and not menu.exists()
    print("MSI smoke passed: installation, x64 app and CLI, assets, protected data, ledger, monthly SQLite, widgets, uninstall")
    if upgrade_from:
        print("MSI upgrade passed: previous product replaced, downgrade blocked, previous data and settings preserved")
    else:
        print("MSI migration passed: isolated schema 22 library migrated to schema 24")
    if isolate_identities:
        print("MSI scope verified: test-only identity transforms, production registration preserved")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--legacy-cli", type=Path)
    parser.add_argument("--upgrade-from", type=Path, help="Optional already-built older MSI for an isolated upgrade test.")
    isolation = parser.add_mutually_exclusive_group()
    isolation.add_argument("--register-shell", action="store_true", help="Use only with a disposable Windows account.")
    isolation.add_argument("--isolate-identities", action="store_true", help="Use ephemeral instance transforms when the production product family is already installed.")
    args = parser.parse_args()
    smoke(args.package.resolve(strict=True), args.legacy_cli, args.register_shell, args.upgrade_from, args.isolate_identities)
