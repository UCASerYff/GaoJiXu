"""Windows notification-area menu and business reminders."""

from __future__ import annotations

import ctypes
import logging
import os
import sys
import threading
from ctypes import wintypes as win
from typing import Callable

from gaojixu.version import APP_NAME

_log = logging.getLogger(__name__)
_wndproc = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(win.LPARAM, win.HWND, win.UINT, win.WPARAM, win.LPARAM)

_WM_NULL = 0
_WM_CLOSE = 0x0010
_WM_DESTROY = 0x0002
_WM_CONTEXTMENU = 0x007B
_WM_TIMER = 0x0113
_WM_LBUTTONDBLCLK = 0x0203
_WM_RBUTTONUP = 0x0205
_WM_TRAY = 0x8001
_NIN_SELECT = 0x0400
_NIN_KEYSELECT = 0x0401
_NIN_BALLOONUSERCLICK = 0x0405
_NIM_ADD, _NIM_MODIFY, _NIM_DELETE, _NIM_SETFOCUS, _NIM_SETVERSION = range(5)
_NIF_MESSAGE, _NIF_ICON, _NIF_TIP, _NIF_INFO, _NIF_SHOWTIP = 0x01, 0x02, 0x04, 0x10, 0x80
_NIIF_INFO, _NIIF_RESPECT_QUIET_TIME = 0x01, 0x80
_TPM_RIGHTBUTTON, _TPM_NONOTIFY, _TPM_RETURNCMD = 0x02, 0x80, 0x100


class _WindowClass(ctypes.Structure):
    _fields_ = [
        ("style", win.UINT), ("procedure", _wndproc),
        ("class_extra", ctypes.c_int), ("window_extra", ctypes.c_int),
        ("instance", win.HINSTANCE), ("icon", win.HICON), ("cursor", win.HANDLE),
        ("background", win.HBRUSH), ("menu", win.LPCWSTR), ("name", win.LPCWSTR),
    ]


class _NotifyIconData(ctypes.Structure):
    _fields_ = [
        ("size", win.DWORD), ("window", win.HWND), ("identifier", win.UINT),
        ("flags", win.UINT), ("message", win.UINT), ("icon", win.HICON),
        ("tip", win.WCHAR * 128), ("state", win.DWORD), ("state_mask", win.DWORD),
        ("body", win.WCHAR * 256), ("version", win.UINT), ("title", win.WCHAR * 64),
        ("info_flags", win.DWORD), ("guid", ctypes.c_byte * 16), ("balloon_icon", win.HICON),
    ]


def _api(dll, name, returns, *args):
    function = getattr(dll, name)
    function.restype = returns
    function.argtypes = args
    return function


class _Windows:
    def __init__(self):
        user = ctypes.WinDLL("user32", use_last_error=True)
        shell = ctypes.WinDLL("shell32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.module_handle = _api(kernel, "GetModuleHandleW", win.HMODULE, win.LPCWSTR)
        self.register_class = _api(user, "RegisterClassW", win.ATOM, ctypes.POINTER(_WindowClass))
        self.unregister_class = _api(user, "UnregisterClassW", win.BOOL, win.LPCWSTR, win.HINSTANCE)
        self.create_window = _api(
            user, "CreateWindowExW", win.HWND, win.DWORD, win.LPCWSTR, win.LPCWSTR, win.DWORD,
            ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, win.HWND, win.HMENU, win.HINSTANCE, win.LPVOID,
        )
        self.destroy_window = _api(user, "DestroyWindow", win.BOOL, win.HWND)
        self.default_procedure = _api(user, "DefWindowProcW", win.LPARAM, win.HWND, win.UINT, win.WPARAM, win.LPARAM)
        self.post_message = _api(user, "PostMessageW", win.BOOL, win.HWND, win.UINT, win.WPARAM, win.LPARAM)
        self.get_message = _api(user, "GetMessageW", win.BOOL, ctypes.POINTER(win.MSG), win.HWND, win.UINT, win.UINT)
        self.dispatch_message = _api(user, "DispatchMessageW", win.LPARAM, ctypes.POINTER(win.MSG))
        self.post_quit = _api(user, "PostQuitMessage", None, ctypes.c_int)
        self.set_timer = _api(user, "SetTimer", win.WPARAM, win.HWND, win.WPARAM, win.UINT, win.LPVOID)
        self.register_message = _api(user, "RegisterWindowMessageW", win.UINT, win.LPCWSTR)
        self.notify = _api(shell, "Shell_NotifyIconW", win.BOOL, win.DWORD, ctypes.POINTER(_NotifyIconData))
        self.extract_icon = _api(
            shell, "ExtractIconExW", win.UINT, win.LPCWSTR, ctypes.c_int, ctypes.POINTER(win.HICON),
            ctypes.POINTER(win.HICON), win.UINT,
        )
        self.load_icon = _api(user, "LoadIconW", win.HICON, win.HINSTANCE, win.LPVOID)
        self.destroy_icon = _api(user, "DestroyIcon", win.BOOL, win.HICON)
        self.create_menu = _api(user, "CreatePopupMenu", win.HMENU)
        self.add_menu_item = _api(user, "AppendMenuW", win.BOOL, win.HMENU, win.UINT, win.WPARAM, win.LPCWSTR)
        self.destroy_menu = _api(user, "DestroyMenu", win.BOOL, win.HMENU)
        self.cursor_position = _api(user, "GetCursorPos", win.BOOL, ctypes.POINTER(win.POINT))
        self.foreground = _api(user, "SetForegroundWindow", win.BOOL, win.HWND)
        self.track_menu = _api(
            user, "TrackPopupMenu", ctypes.c_int, win.HMENU, win.UINT, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, win.HWND, ctypes.POINTER(win.RECT),
        )


def _short_text(value: str, capacity: int) -> str:
    encoded = value.replace("\0", "").encode("utf-16-le")
    return encoded[: (capacity - 1) * 2].decode("utf-16-le", errors="ignore")


class TrayIcon:
    def __init__(self, open_window, exit_app, next_notice, open_adventure):
        self._windows = _Windows()
        self._menu = [(f"打开{APP_NAME}", open_window)]
        if open_adventure is not None:
            self._menu.append(("勇者冒险", open_adventure))
        self._menu.append(("退出", exit_app))
        self._next_notice = next_notice
        self._callback = _wndproc(self._window_message)
        self._thread = threading.Thread(target=self._run, name="gaojixu-tray", daemon=True)
        self._ready = threading.Event()
        self._closing = threading.Event()
        self._window = None
        self._icon = None
        self._registered = False
        self._modern_events = False
        self._taskbar_created = self._windows.register_message("TaskbarCreated")

    def close(self) -> None:
        self._closing.set()
        if self._window:
            self._windows.post_message(self._window, _WM_CLOSE, 0, 0)
        self._thread.join(timeout=2)

    def _icon_data(self, window) -> _NotifyIconData:
        data = _NotifyIconData()
        data.size = ctypes.sizeof(data)
        data.window = window
        data.identifier = 1
        return data

    def _attach(self, window) -> None:
        data = self._icon_data(window)
        data.flags = _NIF_MESSAGE | _NIF_ICON | _NIF_TIP | _NIF_SHOWTIP
        data.message = _WM_TRAY
        data.icon = self._icon
        data.tip = APP_NAME
        self._registered = bool(self._windows.notify(_NIM_ADD, ctypes.byref(data)))
        if self._registered:
            data.version = 4
            self._modern_events = bool(self._windows.notify(_NIM_SETVERSION, ctypes.byref(data)))

    def _poll_notice(self, window) -> None:
        if not self._registered or self._next_notice is None:
            return
        notice = self._next_notice()
        if notice is not None:
            title, body = notice
            data = self._icon_data(window)
            data.flags = _NIF_INFO
            data.info_flags = _NIIF_INFO | _NIIF_RESPECT_QUIET_TIME
            data.title = _short_text(title, 64)
            data.body = _short_text(body, 256)
            self._windows.notify(_NIM_MODIFY, ctypes.byref(data))

    def _show_menu(self, window) -> None:
        api = self._windows
        menu = api.create_menu()
        if not menu:
            return
        try:
            for command, (label, _) in enumerate(self._menu, 1):
                api.add_menu_item(menu, 0, command, label)
            position = win.POINT()
            api.cursor_position(ctypes.byref(position))
            api.foreground(window)
            flags = _TPM_RIGHTBUTTON | _TPM_NONOTIFY | _TPM_RETURNCMD
            selected = api.track_menu(menu, flags, position.x, position.y, 0, window, None)
            api.post_message(window, _WM_NULL, 0, 0)
            if 1 <= selected <= len(self._menu):
                self._menu[selected - 1][1]()
            else:
                api.notify(_NIM_SETFOCUS, ctypes.byref(self._icon_data(window)))
        finally:
            api.destroy_menu(menu)

    def _window_message(self, window, message, wparam, lparam):
        try:
            if message == _WM_TRAY:
                event = lparam & 0xFFFF
                if event in {_NIN_SELECT, _NIN_KEYSELECT, _NIN_BALLOONUSERCLICK, _WM_LBUTTONDBLCLK}:
                    self._menu[0][1]()
                elif event == _WM_CONTEXTMENU or (event == _WM_RBUTTONUP and not self._modern_events):
                    self._show_menu(window)
                return 0
            if message == _WM_TIMER:
                if not self._registered:
                    self._attach(window)
                self._poll_notice(window)
                return 0
            if message == self._taskbar_created:
                self._attach(window)
                return 0
            if message == _WM_DESTROY:
                self._windows.notify(_NIM_DELETE, ctypes.byref(self._icon_data(window)))
                self._windows.post_quit(0)
                return 0
        except Exception:
            _log.exception("Windows notification area callback failed")
        return self._windows.default_procedure(window, message, wparam, lparam)

    def _run(self) -> None:
        api = self._windows
        instance = api.module_handle(None)
        class_name = f"GaoJiXuNotificationArea_{os.getpid()}_{threading.get_ident()}"
        window_class = _WindowClass(procedure=self._callback, instance=instance, name=class_name)
        owned_icon = win.HICON()
        registered_class = api.register_class(ctypes.byref(window_class))
        if not registered_class:
            self._ready.set()
            return
        try:
            api.extract_icon(sys.executable, 0, None, ctypes.byref(owned_icon), 1)
            self._icon = owned_icon.value or api.load_icon(None, 32512)
            self._window = api.create_window(0, class_name, APP_NAME, 0, 0, 0, 0, 0, None, None, instance, None)
            if not self._window:
                return
            if self._closing.is_set():
                api.destroy_window(self._window)
                return
            self._attach(self._window)
            api.set_timer(self._window, 1, 30_000, None)
            api.post_message(self._window, _WM_TIMER, 1, 0)
            self._ready.set()
            message = win.MSG()
            while api.get_message(ctypes.byref(message), None, 0, 0) > 0:
                api.dispatch_message(ctypes.byref(message))
        finally:
            self._window = None
            self._ready.set()
            if owned_icon.value:
                api.destroy_icon(owned_icon)
            api.unregister_class(class_name, instance)


def start_tray(
    open_window: Callable[[], None],
    exit_app: Callable[[], None],
    next_notice: Callable[[], tuple[str, str] | None] | None = None,
    *,
    open_adventure: Callable[[], None] | None = None,
) -> TrayIcon | None:
    """Start a background Win32 message pump for interactive launches."""
    if sys.platform != "win32":
        return None
    try:
        tray = TrayIcon(open_window, exit_app, next_notice, open_adventure)
    except OSError:
        _log.exception("Windows notification area is unavailable")
        return None
    tray._thread.start()
    tray._ready.wait(timeout=2)
    return tray
