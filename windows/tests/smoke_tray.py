"""Verify the normal app on a non-input desktop and native Shell registration with a hidden icon."""

from __future__ import annotations

import ctypes as ct
from ctypes import wintypes as win
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener

from smoke_desktop_widgets import ROOT, ProcessInformation, StartupInfo, bind, until
from gaojixu import native_tray
from gaojixu.desktop import DesktopMain, chromium
from gaojixu.desktop_browser import BrowserJob
from gaojixu.desktop_widgets import TYPES
from gaojixu.store import Store

SCRIPT = Path(__file__).resolve()
PRIVATE_NAME = "GaoJiXuTraySmoke_"
WINDOW_PROC = ct.WINFUNCTYPE(win.BOOL, win.HWND, win.LPARAM)
WM_CLOSE = 0x10
NIF_STATE = 0x08
NIS_HIDDEN = 1


def hide_icon(data):
    data.flags |= NIF_STATE
    data.state = data.state_mask = NIS_HIDDEN


def verify_real_shell():
    """Make actual Shell calls without exposing a temporary icon or changing user preferences."""
    calls, actions = [], []
    tray = native_tray.TrayIcon(lambda: actions.append("open"), lambda: actions.append("exit"),
                              None, None, None, None, None)
    actual = tray._windows.notify

    def notify(command, address):
        data = ct.cast(address, ct.POINTER(native_tray._NotifyIconData)).contents
        assert data.identifier == 1
        if command == native_tray._NIM_ADD:
            hide_icon(data)
        accepted = bool(actual(command, address))
        calls.append((command, data.window, accepted))
        return accepted

    tray._windows.notify = notify
    tray._thread.start()
    try:
        assert tray._ready.wait(5) and tray._registered and tray._modern_events
        hwnd = tray._window
        add = (native_tray._NIM_ADD, hwnd, True)
        version = (native_tray._NIM_SETVERSION, hwnd, True)
        delete = (native_tray._NIM_DELETE, hwnd, True)
        assert calls.count(add) == 1 and calls.count(version) == 1
        assert tray._windows.post_message(hwnd, native_tray._WM_TRAY, 0, native_tray._NIN_SELECT)
        until(lambda: actions == ["open"], "native activation dispatch")

        # Model Explorer losing its icon table without restarting the user's shell.
        assert notify(native_tray._NIM_DELETE, ct.byref(tray._icon_data(hwnd)))
        assert tray._taskbar_created
        assert tray._windows.post_message(hwnd, tray._taskbar_created, 0, 0)
        until(lambda: calls.count(add) == 2 and calls.count(version) == 2, "TaskbarCreated re-registration")
    finally:
        tray.close()
    assert calls.count(delete) == 2
    assert not tray._thread.is_alive()
    print("Explorer accepted real hidden Shell_NotifyIconW ADD, SETVERSION, simulated TaskbarCreated recovery and DELETE.")


class PrivateWindows:
    def __init__(self):
        user = ct.WinDLL("user32", use_last_error=True)
        kernel = ct.WinDLL("kernel32", use_last_error=True)
        thread_id = bind(kernel, "GetCurrentThreadId", win.DWORD)
        thread_desktop = bind(user, "GetThreadDesktop", win.HANDLE, win.DWORD)
        object_info = bind(user, "GetUserObjectInformationW", win.BOOL, win.HANDLE, ct.c_int,
                           ct.c_void_p, win.DWORD, ct.POINTER(win.DWORD))
        desktop_name = ct.create_unicode_buffer(128)
        size = win.DWORD()
        assert object_info(thread_desktop(thread_id()), 2, desktop_name, ct.sizeof(desktop_name), ct.byref(size))
        if not desktop_name.value.startswith(PRIVATE_NAME):
            raise RuntimeError("GaoJiXu tray UI smoke requires a private non-input desktop.")
        self.enum = bind(user, "EnumWindows", win.BOOL, WINDOW_PROC, win.LPARAM)
        self.class_name = bind(user, "GetClassNameW", ct.c_int, win.HWND, win.LPWSTR, ct.c_int)
        self.title = bind(user, "GetWindowTextW", ct.c_int, win.HWND, win.LPWSTR, ct.c_int)
        self.pid = bind(user, "GetWindowThreadProcessId", win.DWORD, win.HWND, ct.POINTER(win.DWORD))
        self.visible = bind(user, "IsWindowVisible", win.BOOL, win.HWND)
        self.post = bind(user, "PostMessageW", win.BOOL, win.HWND, win.UINT, win.WPARAM, win.LPARAM)
        self.open_process = bind(kernel, "OpenProcess", win.HANDLE, win.DWORD, win.BOOL, win.DWORD)
        self.wait = bind(kernel, "WaitForSingleObject", win.DWORD, win.HANDLE, win.DWORD)
        self.close_handle = bind(kernel, "CloseHandle", win.BOOL, win.HANDLE)

    def processes(self, pids):
        handles = [self.open_process(0x100000, False, pid) for pid in set(pids)]  # SYNCHRONIZE
        return [handle for handle in handles if handle]

    def find(self, window_kind):
        matches = {}

        @WINDOW_PROC
        def capture(hwnd, _):
            name = ct.create_unicode_buffer(160)
            title = ct.create_unicode_buffer(256)
            self.class_name(hwnd, name, len(name))
            self.title(hwnd, title, len(title))
            is_tray = name.value.startswith("GaoJiXuNotificationArea_")
            is_app = name.value.startswith("Chrome_WidgetWin_") and bool(title.value) and self.visible(hwnd)
            if (window_kind == "tray" and is_tray) or (window_kind == "app" and is_app):
                pid = win.DWORD()
                self.pid(hwnd, ct.byref(pid))
                matches[hwnd] = (pid.value, title.value)
            return True

        self.enum(capture, 0)
        return matches

    def send(self, hwnd, message, event=0):
        assert self.post(hwnd, message, 0, event)


def observe_app(work, arguments):
    """Keep the real startup and Win32 calls, while attaching private debugging and menu selection."""
    PrivateWindows()
    log = work / "events.jsonl"
    browser = chromium()
    assert browser is not None
    if len(arguments) < 2 or arguments[0] != "--data-dir" or Path(arguments[1]).resolve() != (work / "library").resolve():
        raise RuntimeError("The observed app may only use its synthetic profile.")
    actual_init = native_tray._Windows.__init__
    actual_launch = BrowserJob.launch
    actual_sample = DesktopMain._sample

    def record(*row):
        with log.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps([os.getpid(), *row]) + "\n")

    def native_init(api):
        actual_init(api)
        actual_notify = api.notify
        actual_add = api.add_menu_item
        labels = {}

        def add(menu, flags, command, label):
            labels[int(command)] = label
            return actual_add(menu, flags, command, label)

        def select(*_):
            choice = (work / "menu.txt").read_text(encoding="utf-8")
            record("menu", labels, choice)
            return next(ident for ident, label in labels.items() if label == choice)

        def notify(command, address):
            data = ct.cast(address, ct.POINTER(native_tray._NotifyIconData)).contents
            if command == native_tray._NIM_ADD:
                hide_icon(data)
            result = bool(actual_notify(command, address))
            record("notify", command, data.window, data.identifier, result)
            return result

        api.notify = notify
        api.add_menu_item = add
        api.track_menu = select

    def open_process(job, options, **kwargs):
        if not isinstance(options, (list, tuple)) or Path(options[0]).resolve() != browser.resolve():
            raise RuntimeError("The observed app attempted an unexpected secondary executable.")
        root = next((Path(item.split("=", 1)[1]) for item in options if item.startswith("--user-data-dir=")), None)
        if root is None or not root.resolve().is_relative_to(work.resolve()):
            raise RuntimeError("The observed Chromium launch did not use an isolated user-data directory.")
        result = actual_launch(job, [*options, "--remote-debugging-port=0", "--disable-backgrounding-occluded-windows",
                                     "--disable-background-networking", "--disable-component-update",
                                     "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"], **kwargs)
        record("browser", str(root), next(item for item in options if item.startswith("--app=")))
        return result

    def disallow_fallback(*_args, **_kwargs):
        raise RuntimeError("The isolated UI smoke requires a dedicated Chromium profile.")

    def sample(main):
        before = [main._lease, main._hwnd]
        actual_sample(main)
        after = [main._lease, main._hwnd]
        if before != after:
            record("workbench", before, after)

    import webbrowser
    native_tray._Windows.__init__ = native_init
    BrowserJob.launch = open_process
    DesktopMain._sample = sample
    webbrowser.open = disallow_fallback
    sys.argv = [str(ROOT / "launch.py"), *arguments]
    runpy.run_path(str(ROOT / "launch.py"), run_name="__main__")


def run_private(work, evidence, executable=None, *, inspect_main_window=None):
    desktop = PrivateWindows()
    profile, runtime = work / "library", work / "runtime"
    runtime.mkdir()
    store = Store(profile)
    store.create_library()
    env = dict(os.environ, LOCALAPPDATA=str(work / "local"), APPDATA=str(work / "roaming"),
               TEMP=str(runtime), TMP=str(runtime), GAOJIXU_DATA_DIR=str(profile),
               PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1",
               BROWSER=f'"{sys.executable}" -c "raise SystemExit(0)" %s')
    fixture_id = hashlib.sha256(os.path.normcase(str(profile.resolve())).encode("utf-8")).hexdigest()
    locator = runtime / "GaoJiXu" / f"{fixture_id}.port"
    opener = build_opener(ProxyHandler({}))
    app_log = work / "app.txt"
    events = work / "events.jsonl"

    def event_rows():
        if not events.is_file():
            return []
        content = events.read_text(encoding="utf-8")
        # A line without its newline may still be in use by another process.
        return [json.loads(line) for line in content.split("\n")[:-1] if line]

    def start(*arguments, program=executable):
        entry = [str(program)] if program else [sys.executable, "-B", str(SCRIPT), "--observe", str(work)]
        with app_log.open("a", encoding="utf-8") as output:
            return subprocess.Popen([*entry, "--data-dir", str(profile), *arguments], env=env,
                                    stdout=output, stderr=subprocess.STDOUT, creationflags=0x08000000)

    def active():
        try:
            port = int(locator.read_text(encoding="ascii"))
            base = f"http://127.0.0.1:{port}/"
            with opener.open(base + "instance", timeout=.4) as response:
                return base if response.read(128).decode("ascii") == fixture_id else None
        except (OSError, ValueError):
            return None

    def api(base, route, payload=None):
        assert active() == base
        with opener.open(base, timeout=3) as response:
            token = re.search(r'<meta name="gao-token" content="([A-Za-z0-9_-]+)">', response.read().decode())[1]
        data = json.dumps(payload).encode() if payload is not None else None
        with opener.open(Request(base + "api/" + route, data=data, headers={
            "Content-Type": "application/json", "X-Gao-Token": token}), timeout=3) as response:
            return json.load(response)

    def browser_step(base, phase):
        directory = next(Path(row[2]) for row in reversed(event_rows()) if row[1] == "browser" and "?workbench=" in row[3])
        command = ["node", str(ROOT / "tests" / "smoke_tray.mjs"), base, str(directory / "DevToolsActivePort"), phase]
        if evidence:
            command.append(str(evidence))
        result = subprocess.run(command, env=env, timeout=26, capture_output=True, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)

    def one_window(kind):
        windows = desktop.find(kind)
        return next(iter(windows)) if len(windows) == 1 else None

    def choose(tray, label):
        (work / "menu.txt").write_text(label, encoding="utf-8")
        desktop.send(tray, native_tray._WM_TRAY, native_tray._WM_CONTEXTMENU)

    def save_background(base):
        state = api(base, "state")
        result = api(base, "ledger/save", {"kind": "expense", "accountID": state["accounts"][0]["id"],
                     "amount": 31.25, "categoryID": "food", "date": state["today"], "note": "后台合成记账"})
        assert result["ok"]

    def assert_quit(app, base, browser_handles):
        assert app.wait(timeout=20) == 0
        assert active() is None and not locator.exists()
        endpoint = urlsplit(base)
        try:
            connection = socket.create_connection((endpoint.hostname, endpoint.port), timeout=.5)
        except OSError:
            pass
        else:
            connection.close()
            raise AssertionError("Owned server still accepts connections after quit")
        until(lambda: not desktop.find("tray") and not desktop.find("app"), "tray, main window and widgets removed")
        if not executable:
            deletes = [row for row in event_rows() if row[:3] == [app.pid, "notify", native_tray._NIM_DELETE]]
            assert len(deletes) == 1 and deletes[0][4] == 1
        until(lambda: all(desktop.wait(handle, 0) == 0 for handle in browser_handles), "owned Chromium exits")
        assert all(not Path(row[2]).exists() for row in event_rows() if row[:2] == [app.pid, "browser"])

    app = None
    handles = []
    try:
        app = start("--serve", "--no-browser")
        quiet_base = until(active, "test server")
        assert not desktop.find("tray") and not desktop.find("app") and not event_rows()
        assert api(quiet_base, "shutdown", {})["ok"]
        assert app.wait(timeout=10) == 0 and not locator.exists()
        assert start("--version").wait(timeout=10) == 0
        assert not desktop.find("tray") and not event_rows()
        print("CLI and no-browser test server create no tray or browser.", flush=True)
        if executable:
            cli = executable.with_name("GaoJiXu-cli.exe")
            assert cli.is_file(), "The frozen CLI should be next to the GUI executable."
            app = start("--serve", program=cli)
            cli_base = until(active, "frozen CLI server")
            assert not desktop.find("tray") and not desktop.find("app")
            assert api(cli_base, "shutdown", {})["ok"]
            assert app.wait(timeout=10) == 0 and not locator.exists()
            print("Frozen GaoJiXu-cli.exe --serve opens no GUI or tray.", flush=True)

        app = start()
        base = until(active, "ordinary launch instance")
        tray = until(lambda: one_window("tray"), "one native notification-area owner")
        if not executable:
            assert desktop.find("tray")[tray][0] == app.pid
        first_main = until(lambda: one_window("app"), "one actual Chromium app window")
        assert api(base, "state")["status"] == "ready"
        if inspect_main_window:
            inspect_main_window(first_main, base)
        if not executable:
            browser_step(base, "ready")
        desktop.send(first_main, WM_CLOSE)
        until(lambda: not desktop.find("app"), "caption close removes the main window")
        assert app.poll() is None and active() == base and set(desktop.find("tray")) == {tray}
        save_background(base)

        desktop.send(tray, native_tray._WM_TRAY, native_tray._WM_LBUTTONUP)
        restored = until(lambda: one_window("app"), "native icon activation restores one main window")
        if executable:
            assert start().wait(timeout=25) == 0
            assert start("--widget", "calendar").wait(timeout=25) == 0
            until(lambda: len(desktop.find("app")) == 2, "frozen GUI and independent calendar")
            assert set(desktop.find("tray")) == {tray}
            handles = desktop.processes(pid for pid, _ in desktop.find("app").values())
            assert handles and api(base, "shutdown", {})["ok"]
            assert_quit(app, base, handles)
            assert "后台合成记账" in (profile / "library.json").read_text(encoding="utf-8")
            print("Frozen GUI normal entry: one native tray, caption close and IPC write, native reopen, single instance, independent calendar and complete API shutdown.", flush=True)
            return

        browser_step(base, "background")
        desktop.send(restored, WM_CLOSE)
        until(lambda: not desktop.find("app"), "caption close before native menu activation")
        choose(tray, "打开 搞积蓄")
        until(lambda: one_window("app"), "native menu opens the workbench")
        assert start().wait(timeout=10) == 0
        assert start("gaojixu://adventure").wait(timeout=10) == 0
        browser_step(base, "deep-link")
        situation = desktop.find("app"), desktop.find("tray")
        assert len(situation[0]) == 1 and set(situation[1]) == {tray}, situation
        assert start("--widget", "benefits").wait(timeout=10) == 0
        until(lambda: any(row[:2] == [app.pid, "browser"] and "?widget=expenses&" in row[3] for row in event_rows()),
              "old benefits shortcut forwards to fixed expenses")
        for widget_kind in TYPES:
            assert start("--widget", widget_kind).wait(timeout=10) == 0
        until(lambda: len(desktop.find("app")) == 1 + len(TYPES), "main window and all four independently forwarded widgets")
        assert set(desktop.find("tray")) == {tray}
        print("Caption close retains the instance and write path. Tray activation, ordinary relaunch, the WebGL adventure route and four widgets forward without a second tray.", flush=True)

        browser_step(base, "prepare")
        choose(tray, "退出")
        browser_step(base, "cancel")
        assert app.poll() is None and active() == base and set(desktop.find("tray")) == {tray}
        browser_step(base, "save")
        browser_step(base, "in-app-quit-cancel")
        choose(tray, "退出")
        handles = desktop.processes(pid for pid, _ in desktop.find("app").values())
        assert len(handles) >= 2, "The workbench and widgets should have independent Chromium processes."
        browser_step(base, "confirm")
        assert_quit(app, base, handles)
        assert "退出前保存" in (profile / "library.json").read_text(encoding="utf-8")
        print("Native quit confirmation can be canceled, ledger saved, and quit confirmed. Tray, owned windows/processes and IPC are gone.", flush=True)

        app = start()
        base = until(active, "second isolated normal lifetime")
        tray = until(lambda: one_window("tray"), "one fresh tray")
        main = until(lambda: one_window("app"), "one fresh app window")
        desktop.send(main, WM_CLOSE)
        until(lambda: not desktop.find("app"), "caption close before background quit")
        widget = start("--widget", "calendar")
        until(lambda: any(row[:2] == [app.pid, "browser"] and "?widget=" in row[3] for row in event_rows()),
              "the forwarded calendar launcher handed off to the browser job")
        opened = desktop.find("app")
        choose(tray, "退出")
        assert widget.wait(timeout=10) == 0
        assert_quit(app, base, [])
        print(f"Background tray quit stopped the newly launched calendar with {len(opened)} visible HWND at exit dispatch.", flush=True)
    except BaseException:
        if app_log.exists():
            print(app_log.read_text(encoding="utf-8", errors="replace"), flush=True)
        if events.exists():
            print(events.read_text(encoding="utf-8", errors="replace"), flush=True)
        raise
    finally:
        for handle in handles:
            desktop.close_handle(handle)
        for hwnd in desktop.find("app"):
            desktop.send(hwnd, WM_CLOSE)
        if app is not None and app.poll() is None:
            base = active()
            if base:
                try:
                    api(base, "shutdown", {})
                    app.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if app.poll() is None:
                app.kill()
                app.wait(timeout=5)

def launch_private(work, evidence, executable, *, script=SCRIPT):
    user = ct.WinDLL("user32", use_last_error=True)
    kernel = ct.WinDLL("kernel32", use_last_error=True)
    create = bind(user, "CreateDesktopW", win.HANDLE, win.LPCWSTR, win.LPCWSTR, ct.c_void_p,
                  win.DWORD, win.DWORD, ct.c_void_p)
    close = bind(user, "CloseDesktop", win.BOOL, win.HANDLE)
    close_handle = bind(kernel, "CloseHandle", win.BOOL, win.HANDLE)
    new_process = bind(kernel, "CreateProcessW", win.BOOL, win.LPCWSTR, win.LPWSTR, ct.c_void_p, ct.c_void_p,
                       win.BOOL, win.DWORD, ct.c_void_p, win.LPCWSTR,
                       ct.POINTER(StartupInfo), ct.POINTER(ProcessInformation))
    wait = bind(kernel, "WaitForSingleObject", win.DWORD, win.HANDLE, win.DWORD)
    status = bind(kernel, "GetExitCodeProcess", win.BOOL, win.HANDLE, ct.POINTER(win.DWORD))
    terminate = bind(kernel, "TerminateProcess", win.BOOL, win.HANDLE, win.UINT)
    name = PRIVATE_NAME + secrets.token_hex(6)
    desktop = create(name, None, None, 0, 0x00FF, None)
    if not desktop:
        raise ct.WinError(ct.get_last_error())
    child = ProcessInformation()
    try:
        args = [sys.executable, "-B", str(script), "--private-child", str(work)]
        if evidence:
            args += ["--evidence", str(evidence)]
        if executable:
            args += ["--executable", str(executable)]
        command = ct.create_unicode_buffer(subprocess.list2cmdline(args))
        startup = StartupInfo(cb=ct.sizeof(StartupInfo), desktop="winsta0\\" + name)
        if not new_process(sys.executable, command, None, None, True, 0, None, str(ROOT),
                           ct.byref(startup), ct.byref(child)):
            raise ct.WinError(ct.get_last_error())
        if wait(child.process, 150_000) != 0:
            terminate(child.process, 1)
            raise AssertionError("Private desktop tray test did not finish")
        code = win.DWORD()
        assert status(child.process, ct.byref(code)) and code.value == 0, f"Private desktop smoke exited {code.value}"
    finally:
        if child.thread:
            close_handle(child.thread)
        if child.process:
            close_handle(child.process)
        close(desktop)


def cleanup(path):
    # Chromium's system update broker can release a transient TEMP lock after the app exits.
    if path.resolve().parent != Path(tempfile.gettempdir()).resolve() or not path.name.startswith("gaojixu-tray-smoke-"):
        raise RuntimeError("Refusing to clean a directory outside the tray smoke workspace.")
    limit = time.monotonic() + 12
    while path.exists():
        try:
            shutil.rmtree(path)
        except OSError:
            if time.monotonic() >= limit:
                raise
            time.sleep(.15)


if __name__ == "__main__":
    if sys.platform != "win32" or not __debug__:
        raise SystemExit("Windows with Python assertions enabled is required.")
    if sys.argv[1:2] == ["--observe"]:
        observe_app(Path(sys.argv[2]), sys.argv[3:])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--evidence", type=Path)
        parser.add_argument("--executable", type=Path, help="Optional frozen GUI executable for normal-entry smoke")
        mode = parser.add_mutually_exclusive_group()
        mode.add_argument("--private-child", type=Path, help=argparse.SUPPRESS)
        mode.add_argument("--shell-only", action="store_true")
        args = parser.parse_args()
        if args.private_child:
            run_private(args.private_child, args.evidence, args.executable)
        elif args.shell_only:
            verify_real_shell()
        else:
            evidence = args.evidence.resolve() if args.evidence else None
            if evidence:
                evidence.mkdir(parents=True, exist_ok=True)
            executable = args.executable.resolve(strict=True) if args.executable else None
            work = Path(tempfile.mkdtemp(prefix="gaojixu-tray-smoke-")).resolve()
            try:
                launch_private(work, evidence, executable)
            finally:
                cleanup(work)
