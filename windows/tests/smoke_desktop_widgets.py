"""Exercise real Chromium HWNDs on a non-input Windows desktop and leave the active desktop alone."""

from __future__ import annotations

import argparse
import ctypes as ct
from ctypes import wintypes as win
from pathlib import Path
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from gaojixu import monthly
from gaojixu.desktop import chromium
from gaojixu.desktop_widgets import DesktopWidgets, TYPES, WidgetWindows
from gaojixu import native_tray
from gaojixu.store import Store
from gaojixu.web import serve


class StartupInfo(ct.Structure):
    _fields_ = [
        ("cb", win.DWORD), ("reserved", win.LPWSTR), ("desktop", win.LPWSTR), ("title", win.LPWSTR),
        ("x", win.DWORD), ("y", win.DWORD), ("width", win.DWORD), ("height", win.DWORD),
        ("xchars", win.DWORD), ("ychars", win.DWORD), ("fill", win.DWORD), ("flags", win.DWORD),
        ("show", win.WORD), ("reserved_count", win.WORD), ("reserved2", ct.c_void_p),
        ("stdin", win.HANDLE), ("stdout", win.HANDLE), ("stderr", win.HANDLE),
    ]


class ProcessInformation(ct.Structure):
    _fields_ = [("process", win.HANDLE), ("thread", win.HANDLE), ("pid", win.DWORD), ("tid", win.DWORD)]


def bind(dll, name, result, *args):
    function = getattr(dll, name)
    function.restype, function.argtypes = result, args
    return function


def until(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        time.sleep(.1)
    raise AssertionError("Timed out: " + description)


def run_child(work, browser, attempt_notification):
    log = work / "result.txt"

    def note(message):
        with log.open("a", encoding="utf-8") as stream:
            stream.write(message + "\n")

    store = Store(work / "library")
    store.create_library()
    store.create_monthly()
    monthly.save_subscription(store.directory, {"name": "Synthetic plan", "price": 12}, store.now)
    server = serve(store, open_browser=False)
    launched = []

    def launch(options, **kwargs):
        args = [options[0], "--remote-debugging-port=0", "--disable-backgrounding-occluded-windows", *options[1:]]
        process = subprocess.Popen(args, **kwargs)
        launched.append(process)

    native = WidgetWindows()
    manager = DesktopWidgets(server.url, work / "widgets", browser, native, launch=launch)
    server.desktop_widgets = manager
    managers = [manager]
    manager.start()
    try:
        for kind in TYPES:
            manager.open(kind)
            until(lambda: manager.request({"command": "status", "widget": kind}, lambda _: None)["windows"][kind]["open"],
                  kind + " actual Chromium app HWND")
        note("four Chromium app-mode HWNDs separately observed on private desktop")
        action = subprocess.run(
            ["node", str(ROOT / "tests" / "smoke_desktop_widgets.mjs"), server.url, str(manager.base / "Chromium" / "DevToolsActivePort")],
            capture_output=True, encoding="utf-8", timeout=40,
        )
        assert action.returncode == 0, action.stdout + action.stderr
        note(action.stdout.strip())
        calendar = manager._active["calendar"]
        assert native.topmost(calendar.hwnd)
        screen_rect = native.placement(calendar.hwnd)
        assert screen_rect is not None
        left, top, right, bottom = screen_rect
        rect = [left + 23, top + 26, right + 23, bottom + 26]
        native.restore(calendar.hwnd, rect)
        until(lambda: native.placement(calendar.hwnd) == rect, "private desktop move and resize")
        note("WS_EX_TOPMOST independently verified; window rectangle recorded")
        finance = manager._active["net-worth"]
        assert native.topmost(finance.hwnd)
        # Close the net-worth window from its native caption, like the window close button.
        native.close(finance.hwnd)
        until(lambda: not manager.request({"command": "status","widget": "net-worth"}, lambda _: None)["windows"]["net-worth"]["open"],
              "caption-close clears open state")
        exiting = [(window.hwnd, window.lease) for window in manager._active.values()]
        manager.close()
        until(lambda: all(not native.belongs(hwnd, lease) for hwnd, lease in exiting), "native widgets close on app quit")
        restarted = DesktopWidgets(server.url, manager.base, browser, native, launch=launch)
        server.desktop_widgets = restarted
        managers.append(restarted)
        restarted.start()
        restarted.restore()
        until(lambda: restarted.request({"command": "status", "widget": "calendar"}, lambda _: None)["windows"]["calendar"]["pinned"],
              "calendar reopens pinned after restart")
        reopened = restarted._active["calendar"]
        until(lambda: native.placement(reopened.hwnd) == rect, "position survives restart")
        assert set(restarted._active) == {"calendar"}
        note("same native rectangle and pin restored; a caption-closed pinned window and unpinned windows stayed closed")
        if attempt_notification:
            events = []
            tray = native_tray.start_tray(lambda: None, lambda: None, notice_event=events.append)
            try:
                accepted = tray is not None and tray.test_notification("Gao Savings Test", "Isolated reminder evidence.")
                if accepted:
                    deadline = time.monotonic() + 8
                    while "shown" not in events and time.monotonic() < deadline:
                        time.sleep(.1)
                note(f"native notice on private desktop: shell accepted={accepted}, NIN_BALLOONSHOW={'shown' in events}")
            finally:
                if tray:
                    tray.close()
    except Exception:
        note(traceback.format_exc())
        raise
    finally:
        for current in managers:
            current.close()
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()
        for process in launched:
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait()


def private_desktop(work, browser, attempt_notification):
    user = ct.WinDLL("user32", use_last_error=True)
    kernel = ct.WinDLL("kernel32", use_last_error=True)
    create_desktop = bind(user, "CreateDesktopW", win.HANDLE, win.LPCWSTR, win.LPCWSTR, ct.c_void_p, win.DWORD, win.DWORD, ct.c_void_p)
    close_desktop = bind(user, "CloseDesktop", win.BOOL, win.HANDLE)
    close_handle = bind(kernel, "CloseHandle", win.BOOL, win.HANDLE)
    create_process = bind(
        kernel, "CreateProcessW", win.BOOL, win.LPCWSTR, win.LPWSTR, ct.c_void_p, ct.c_void_p,
        win.BOOL, win.DWORD, ct.c_void_p, win.LPCWSTR, ct.POINTER(StartupInfo), ct.POINTER(ProcessInformation),
    )
    wait = bind(kernel, "WaitForSingleObject", win.DWORD, win.HANDLE, win.DWORD)
    terminate = bind(kernel, "TerminateProcess", win.BOOL, win.HANDLE, win.UINT)
    status = bind(kernel, "GetExitCodeProcess", win.BOOL, win.HANDLE, ct.POINTER(win.DWORD))
    name = "GaoJiXuTest_" + secrets.token_hex(6)
    desktop = create_desktop(name, None, None, 0, 0x00FF, None)
    if not desktop:
        raise ct.WinError(ct.get_last_error())
    process = ProcessInformation()
    try:
        options = [sys.executable, str(Path(__file__).resolve()), "--child", str(work), "--browser", str(browser)]
        if attempt_notification:
            options.append("--notification")
        command = ct.create_unicode_buffer(subprocess.list2cmdline(options))
        info = StartupInfo(cb=ct.sizeof(StartupInfo), desktop="winsta0\\" + name)
        if not create_process(sys.executable, command, None, None, False, 0x08000000, None, str(ROOT), ct.byref(info), ct.byref(process)):
            raise ct.WinError(ct.get_last_error())
        log = work / "result.txt"
        deadline = time.monotonic() + 100
        written = 0
        while True:
            outcome = wait(process.process, 700)
            if log.exists():
                report = log.read_text(encoding="utf-8")
                if len(report) > written:
                    print(report[written:], end="", flush=True)
                    written = len(report)
            if outcome == 0:
                break
            if time.monotonic() >= deadline:
                terminate(process.process, 1)
                raise AssertionError("Private desktop smoke test timed out")
        code = win.DWORD()
        assert status(process.process, ct.byref(code)) and code.value == 0, f"Private desktop exited {code.value}"
    finally:
        if process.thread:
            close_handle(process.thread)
        if process.process:
            close_handle(process.process)
        close_desktop(desktop)


def verify_shell_registration():
    """Register a hidden tray icon and exercise callbacks without submitting a balloon."""
    polled = threading.Event()
    invoked = threading.Event()
    events = []
    tray = native_tray.TrayIcon(lambda: None, lambda: None, polled.set, None, None, invoked.set, events.append)
    actual_notify = tray._windows.notify

    def hidden_icon(command, address):
        data = ct.cast(address, ct.POINTER(native_tray._NotifyIconData)).contents
        assert not data.flags & native_tray._NIF_INFO
        if command == native_tray._NIM_ADD:
            data.flags |= 0x08  # NIF_STATE
            data.state = data.state_mask = 1  # NIS_HIDDEN
        return actual_notify(command, address)

    tray._windows.notify = hidden_icon
    tray._thread.start()
    try:
        assert tray._ready.wait(2) and tray._registered and tray._modern_events, "Windows Shell did not register hidden tray icon"
        assert polled.wait(2), "Tray reminder timer did not call the notification source"
        assert tray._windows.post_message(tray._window, native_tray._WM_TRAY, 0, native_tray._NIN_BALLOONUSERCLICK)
        assert invoked.wait(2) and events == ["clicked"], "Win32 callback did not dispatch the fixed-expense route"
        print("Shell_NotifyIconW NIM_ADD and NIM_SETVERSION succeeded for a hidden icon")
        print("Native timer callback and synthetic balloon click work; no notification banner was submitted")
    finally:
        tray.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--child", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--browser", type=Path, default=chromium())
    parser.add_argument("--notification", action="store_true")
    parser.add_argument("--verify-shell-registration", action="store_true")
    config = parser.parse_args()
    if not config.browser or sys.platform != "win32":
        raise SystemExit("Windows and an installed Chromium browser are required")
    if config.verify_shell_registration:
        verify_shell_registration()
    elif config.child:
        run_child(config.child, config.browser, config.notification)
    else:
        with tempfile.TemporaryDirectory(prefix="gaojixu-private-desktop-") as folder:
            private_desktop(Path(folder), config.browser, config.notification)
