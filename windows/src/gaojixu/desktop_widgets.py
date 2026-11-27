"""Manage independent Chromium app windows as per-library desktop widgets."""

from __future__ import annotations

import ctypes
from ctypes import wintypes as win
from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
from urllib.parse import urlencode

from gaojixu.errors import AppError

_logger = logging.getLogger(__name__)
TYPES = {
    "calendar": ((432, 488), "ledger"),
    "net-worth": ((310, 262), "overview"),
    "expenses": ((356, 328), "fixed-expenses"),
    "benefits": ((356, 328), "benefits"),
    "adventure": ((462, 344), "adventure"),
}
_EnumProc = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(win.BOOL, win.HWND, win.LPARAM)


class _WindowPlacement(ctypes.Structure):
    _fields_ = [
        ("length", win.UINT), ("flags", win.UINT), ("show", win.UINT),
        ("minimum", win.POINT), ("maximum", win.POINT), ("normal", win.RECT),
    ]


class WidgetWindows:
    def __init__(self):
        user = ctypes.WinDLL("user32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)

        def bind(dll, name, restype, *args):
            fn = getattr(dll, name)
            fn.restype, fn.argtypes = restype, args
            return fn

        self._enumerate = bind(user, "EnumWindows", win.BOOL, _EnumProc, win.LPARAM)
        self._title = bind(user, "GetWindowTextW", ctypes.c_int, win.HWND, win.LPWSTR, ctypes.c_int)
        self._classname = bind(user, "GetClassNameW", ctypes.c_int, win.HWND, win.LPWSTR, ctypes.c_int)
        self._pid = bind(user, "GetWindowThreadProcessId", win.DWORD, win.HWND, ctypes.POINTER(win.DWORD))
        self._open_process = bind(kernel, "OpenProcess", win.HANDLE, win.DWORD, win.BOOL, win.DWORD)
        self._process_image = bind(kernel, "QueryFullProcessImageNameW", win.BOOL, win.HANDLE, win.DWORD, win.LPWSTR, ctypes.POINTER(win.DWORD))
        self._close_handle = bind(kernel, "CloseHandle", win.BOOL, win.HANDLE)
        self._set_identity = bind(user, "SetPropW", win.BOOL, win.HWND, win.LPCWSTR, win.HANDLE)
        self._identity = bind(user, "GetPropW", win.HANDLE, win.HWND, win.LPCWSTR)
        self._get_style = bind(user, "GetWindowLongPtrW", win.LPARAM, win.HWND, ctypes.c_int)
        self._position = bind(user, "SetWindowPos", win.BOOL, win.HWND, win.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, win.UINT)
        self._get_placement = bind(user, "GetWindowPlacement", win.BOOL, win.HWND, ctypes.POINTER(_WindowPlacement))
        self._set_placement = bind(user, "SetWindowPlacement", win.BOOL, win.HWND, ctypes.POINTER(_WindowPlacement))
        self._show = bind(user, "ShowWindowAsync", win.BOOL, win.HWND, ctypes.c_int)
        self._iconic = bind(user, "IsIconic", win.BOOL, win.HWND)
        self._visible = bind(user, "IsWindowVisible", win.BOOL, win.HWND)
        self._foreground = bind(user, "SetForegroundWindow", win.BOOL, win.HWND)
        self._post = bind(user, "PostMessageW", win.BOOL, win.HWND, win.UINT, win.WPARAM, win.LPARAM)
        self._dpi = bind(user, "SetThreadDpiAwarenessContext", win.HANDLE, win.HANDLE)

    def _matches_image(self, hwnd, executable):
        pid = win.DWORD()
        if not self._pid(hwnd, ctypes.byref(pid)):
            return False
        process = self._open_process(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not process:
            return False
        try:
            image = ctypes.create_unicode_buffer(32768)
            size = win.DWORD(len(image))
            return bool(self._process_image(process, 0, image, ctypes.byref(size))) and os.path.normcase(image.value) == executable
        finally:
            self._close_handle(process)

    def discover(self, lease, executable):
        marker = f"[GJX:{lease}]"
        property_name = f"GaoJiXuWidget.{lease}"
        match = None

        @_EnumProc
        def find(hwnd, _):
            title = ctypes.create_unicode_buffer(160)
            name = ctypes.create_unicode_buffer(96)
            self._title(hwnd, title, len(title))
            if marker not in title.value:
                return True
            self._classname(hwnd, name, len(name))
            if not (name.value.startswith("Chrome_WidgetWin_") and self._matches_image(hwnd, executable)):
                return True
            if self._set_identity(hwnd, property_name, 1):
                nonlocal match
                match = hwnd
                return False
            return True

        self._enumerate(find, 0)
        return match

    def belongs(self, hwnd, lease):
        return self._identity(hwnd, f"GaoJiXuWidget.{lease}") == 1

    def visible(self, hwnd):
        return bool(self._visible(hwnd))

    def topmost(self, hwnd):
        return bool(self._get_style(hwnd, -20) & 0x8)  # GWL_EXSTYLE / WS_EX_TOPMOST

    def pin(self, hwnd, requested):
        # SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS.
        if not self._position(hwnd, -1 if requested else -2, 0, 0, 0, 0, 0x4013):
            return False
        deadline = time.monotonic() + .75
        while self.topmost(hwnd) != requested:
            if time.monotonic() >= deadline:
                return False
            time.sleep(.025)
        return True

    def placement(self, hwnd):
        previous = self._dpi(-4)  # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        try:
            position = _WindowPlacement(length=ctypes.sizeof(_WindowPlacement))
            if self._get_placement(hwnd, ctypes.byref(position)):
                rect = position.normal
                return [rect.left, rect.top, rect.right, rect.bottom]
            return None
        finally:
            if previous:
                self._dpi(previous)

    def restore(self, hwnd, rect):
        previous = self._dpi(-4)
        try:
            if rect is None:
                self._show(hwnd, 4)  # SW_SHOWNOACTIVATE
            else:
                position = _WindowPlacement(
                    length=ctypes.sizeof(_WindowPlacement), flags=4, show=4,
                    normal=win.RECT(*rect),
                )
                self._set_placement(hwnd, ctypes.byref(position))
        finally:
            if previous:
                self._dpi(previous)

    def activate(self, hwnd):
        if self._iconic(hwnd):
            self._show(hwnd, 9)  # SW_RESTORE
        self._foreground(hwnd)

    def close(self, hwnd):
        self._post(hwnd, 0x10, 0, 0)  # WM_CLOSE


@dataclass
class _DesktopWindow:
    kind: str
    lease: str
    deadline: float
    restored: bool = False
    hwnd: int | None = None


def _valid_rect(value):
    if not isinstance(value, list) or len(value) != 4 or any(type(x) is not int or abs(x) > 100000 for x in value):
        return False
    left, top, right, bottom = value
    return 150 <= right - left <= 16000 and 130 <= bottom - top <= 16000


class DesktopWidgets:
    def __init__(self, url, base, executable, windows, *, launch=subprocess.Popen, browser_profile=None):
        self.url = url
        self.base = Path(base)
        self.executable = os.path.normcase(str(Path(executable).resolve()))
        self.native = windows
        self._launch = launch
        self._browser_profile = browser_profile or self.base / "Chromium"
        self._lock = threading.RLock()
        self._stopping = threading.Event()
        self._worker = None
        self._active = {}
        self._layout_file = self.base / "layout.json"
        self._saved, self._persistable = self._read_layout()
        self._last_saved = time.monotonic()
        self._dirty = False

    def _read_layout(self):
        try:
            data = json.loads(self._layout_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}, True
        except (OSError, ValueError):
            return {}, False
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("windows"), dict):
            return {}, False
        result = {}
        for kind, entry in data["windows"].items():
            if kind in TYPES and isinstance(entry, dict):
                result[kind] = {
                    "open": entry.get("open") is True, "pinned": entry.get("pinned") is True,
                    "rect": entry["rect"] if _valid_rect(entry.get("rect")) else None,
                }
        return result, True

    def _save(self, *, force=False):
        if not self._dirty or not self._persistable or (not force and time.monotonic() < self._last_saved + 1.5):
            return
        try:
            self._layout_file.parent.mkdir(parents=True, exist_ok=True)
            pending = self._layout_file.with_suffix(".tmp")
            pending.write_text(json.dumps({"version": 1, "windows": self._saved}, ensure_ascii=False), encoding="utf-8")
            pending.replace(self._layout_file)
        except OSError:
            _logger.warning("Could not save desktop widget appearance", exc_info=True)
        else:
            self._dirty = False
        finally:
            self._last_saved = time.monotonic()

    def start(self):
        self._worker = threading.Thread(target=self._run, name="gaojixu-desktop-widgets", daemon=True)
        self._worker.start()

    def restore(self):
        with self._lock:
            restore = [kind for kind, saved in self._saved.items() if saved["pinned"] and saved["open"]]
        for kind in restore:
            try:
                self.open(kind, restored=True)
            except AppError:
                _logger.warning("Could not restore widget %s", kind)

    def _change(self, kind, **fields):
        saved = self._saved.setdefault(kind, {"open": False, "pinned": False, "rect": None})
        if any(saved.get(key) != value for key, value in fields.items()):
            saved.update(fields)
            self._dirty = True

    def _samples(self):
        for kind, window in list(self._active.items()):
            if window.hwnd:
                if self.native.belongs(window.hwnd, window.lease):
                    rect = self.native.placement(window.hwnd)
                    if _valid_rect(rect):
                        self._change(kind, rect=rect)
                    continue
                self._change(kind, open=False)
                del self._active[kind]
                continue
            hwnd = self.native.discover(window.lease, self.executable)
            if hwnd:
                window.hwnd = hwnd
                saved = self._saved.get(kind, {})
                if saved.get("rect") is not None or window.restored:
                    self.native.restore(hwnd, saved.get("rect"))
                if saved.get("pinned") and not self.native.pin(hwnd, True):
                    _logger.warning("Could not restore pinned state for widget %s", kind)
                self._change(kind, open=True)
            elif time.monotonic() > window.deadline:
                del self._active[kind]

    def _run(self):
        while not self._stopping.wait(.75):
            with self._lock:
                self._samples()
                self._save()

    def close(self):
        self._stopping.set()
        if self._worker:
            self._worker.join(timeout=2)
        with self._lock:
            self._samples()
            self._save(force=True)
            for window in self._active.values():
                if window.hwnd and self.native.belongs(window.hwnd, window.lease):
                    self.native.close(window.hwnd)

    def open(self, kind, *, restored=False):
        if kind not in TYPES or self._stopping.is_set():
            raise AppError("无法打开此小组件。", "desktop-widget")
        with self._lock:
            if self._stopping.is_set():
                raise AppError("无法打开此小组件。", "desktop-widget")
            self._samples()
            window = self._active.get(kind)
            if window is not None:
                if window.hwnd and not restored:
                    self.native.activate(window.hwnd)
                return self._status(kind)
            lease = secrets.token_hex(16)
            width, height = TYPES[kind][0]
            options = [
                self.executable, f"--user-data-dir={self._browser_profile}", "--no-first-run",
                "--no-default-browser-check", "--disable-background-mode", f"--window-size={width},{height}",
                "--app=" + self.url + "?" + urlencode({"widget": kind, "desktop": lease}),
            ]
            if restored:
                options.insert(-1, "--start-minimized")
            try:
                self.base.mkdir(parents=True, exist_ok=True)
                self._launch(options, close_fds=True)
            except OSError as exc:
                raise AppError("无法打开 Windows 小组件窗口。", "desktop-widget") from exc
            self._active[kind] = _DesktopWindow(kind, lease, time.monotonic() + 30, restored)
            return self._status(kind)

    def _status(self, kind):
        window = self._active.get(kind)
        return {
            "attaching": bool(window and not window.hwnd),
            "open": bool(window and window.hwnd),
            "pinned": bool(window and window.hwnd and self.native.topmost(window.hwnd)),
        }

    def request(self, payload, open_route):
        kind, command = payload.get("widget"), payload.get("command")
        if command == "status":
            with self._lock:
                self._samples()
                current = self._active.get(kind) if isinstance(kind, str) else None
                return {
                    "available": True,
                    "currentAttached": bool(current and current.hwnd and current.lease == payload.get("lease")),
                    "windows": {widget_type: self._status(widget_type) for widget_type in TYPES},
                }
        if not isinstance(kind, str) or kind not in TYPES:
            raise AppError("无法识别此小组件。", "desktop-widget")
        if command == "open":
            return self.open(kind)
        with self._lock:
            self._samples()
            window = self._active.get(kind)
            if not window or not window.hwnd or window.lease != payload.get("lease"):
                raise AppError("未连接到此 Windows 小组件窗口。", "desktop-widget")
            if command == "pin":
                pinned = payload.get("pinned")
                if type(pinned) is not bool or not self.native.pin(window.hwnd, pinned):
                    raise AppError("Windows 未能应用固定设置。", "desktop-widget")
                self._change(kind, pinned=pinned)
                rect = self.native.placement(window.hwnd)
                if _valid_rect(rect):
                    self._change(kind, rect=rect)
                self._save(force=True)
            elif command == "close":
                self._change(kind, open=False)
                self._save(force=True)
                self.native.close(window.hwnd)
            elif command == "route":
                open_route(TYPES[kind][1])
            else:
                raise AppError("无法识别此小组件操作。", "desktop-widget")
            return self._status(kind)
