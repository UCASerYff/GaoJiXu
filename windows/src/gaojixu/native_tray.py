"""Windows notification-area menu and business reminders."""

from __future__ import annotations

import ctypes
import locale
import logging
import os
import queue
import sys
import threading
import time
from ctypes import wintypes as win
from typing import Callable

from gaojixu.version import APP_NAME

_log = logging.getLogger(__name__)
_wndproc = getattr(ctypes, "WINFUNCTYPE", ctypes.CFUNCTYPE)(win.LPARAM, win.HWND, win.UINT, win.WPARAM, win.LPARAM)

_WM_NULL = 0
_WM_CLOSE = 0x0010
_WM_DESTROY = 0x0002
_WM_CONTEXTMENU = 0x007B
_WM_DISPLAYCHANGE = 0x007E
_WM_TIMER = 0x0113
_WM_LBUTTONUP = 0x0202
_WM_RBUTTONUP = 0x0205
_WM_DPICHANGED = 0x02E0
_WM_TRAY = 0x8001
_WM_NOTICE = 0x8002
_NIN_SELECT = 0x0400
_NIN_KEYSELECT = 0x0401
_NIN_BALLOONSHOW = 0x0402
_NIN_BALLOONHIDE = 0x0403
_NIN_BALLOONTIMEOUT = 0x0404
_NIN_BALLOONUSERCLICK = 0x0405
_NIM_ADD, _NIM_MODIFY, _NIM_DELETE, _NIM_SETFOCUS, _NIM_SETVERSION = range(5)
_NIF_MESSAGE, _NIF_ICON, _NIF_TIP, _NIF_INFO, _NIF_SHOWTIP = 0x01, 0x02, 0x04, 0x10, 0x80
_NIIF_INFO, _NIIF_RESPECT_QUIET_TIME = 0x01, 0x80
_TPM_RIGHTBUTTON, _TPM_NONOTIFY, _TPM_RETURNCMD = 0x02, 0x80, 0x100
_ICON_ID = 1
_TRAY_TIMER = 1
_SM_CXSMICON, _SM_CYSMICON = 49, 50
_IMAGE_ICON, _LR_LOADFROMFILE = 1, 0x10
_PER_MONITOR_AWARE, _PER_MONITOR_AWARE_V2 = -3, -4
_CLICK_INTERVAL = .25


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


class _NotifyIconIdentifier(ctypes.Structure):
    _fields_ = [
        ("size", win.DWORD), ("window", win.HWND), ("identifier", win.UINT),
        ("guid", ctypes.c_byte * 16),
    ]


def _api(dll, name, returns, *args):
    function = getattr(dll, name)
    function.restype = returns
    function.argtypes = args
    return function


def _optional_api(dll, name, returns, *args):
    return _api(dll, name, returns, *args) if hasattr(dll, name) else None


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
        self.kill_timer = _api(user, "KillTimer", win.BOOL, win.HWND, win.WPARAM)
        self.register_message = _api(user, "RegisterWindowMessageW", win.UINT, win.LPCWSTR)
        self.notify = _api(shell, "Shell_NotifyIconW", win.BOOL, win.DWORD, ctypes.POINTER(_NotifyIconData))
        self.icon_rect = _api(
            shell, "Shell_NotifyIconGetRect", win.LONG, ctypes.POINTER(_NotifyIconIdentifier), ctypes.POINTER(win.RECT),
        )
        self.extract_icon = _api(
            shell, "SHDefExtractIconW", win.LONG, win.LPCWSTR, ctypes.c_int, win.UINT,
            ctypes.POINTER(win.HICON), ctypes.POINTER(win.HICON), win.UINT,
        )
        self.load_icon = _api(user, "LoadIconW", win.HICON, win.HINSTANCE, win.LPVOID)
        self.load_image = _api(
            user, "LoadImageW", win.HANDLE, win.HINSTANCE, win.LPCWSTR, win.UINT,
            ctypes.c_int, ctypes.c_int, win.UINT,
        )
        self.metrics = _api(user, "GetSystemMetrics", ctypes.c_int, ctypes.c_int)
        self.metrics_for_dpi = _optional_api(user, "GetSystemMetricsForDpi", ctypes.c_int, ctypes.c_int, win.UINT)
        self.find_window = _api(user, "FindWindowW", win.HWND, win.LPCWSTR, win.LPCWSTR)
        self.dpi_for_window = _optional_api(user, "GetDpiForWindow", win.UINT, win.HWND)
        self.system_dpi = _optional_api(user, "GetDpiForSystem", win.UINT)
        self.set_thread_dpi_context = _optional_api(user, "SetThreadDpiAwarenessContext", win.HANDLE, win.HANDLE)
        self.destroy_icon = _api(user, "DestroyIcon", win.BOOL, win.HICON)
        self.create_menu = _api(user, "CreatePopupMenu", win.HMENU)
        self.add_menu_item = _api(user, "AppendMenuW", win.BOOL, win.HMENU, win.UINT, win.WPARAM, win.LPCWSTR)
        self.destroy_menu = _api(user, "DestroyMenu", win.BOOL, win.HMENU)
        self.end_menu = _api(user, "EndMenu", win.BOOL)
        self.cursor_position = _api(user, "GetCursorPos", win.BOOL, ctypes.POINTER(win.POINT))
        self.foreground = _api(user, "SetForegroundWindow", win.BOOL, win.HWND)
        self.track_menu = _api(
            user, "TrackPopupMenu", ctypes.c_int, win.HMENU, win.UINT, ctypes.c_int, ctypes.c_int,
            ctypes.c_int, win.HWND, ctypes.POINTER(win.RECT),
        )

    def tray_icon_size(self, window, dpi_hint=0) -> tuple[int, int]:
        # The message sink can belong to a different monitor than Explorer's notification area.
        if self.metrics_for_dpi and self.dpi_for_window:
            taskbar = self.find_window("Shell_TrayWnd", None)
            dpi = (self.dpi_for_window(taskbar) if taskbar else 0) or dpi_hint or self.dpi_for_window(window)
            dpi = dpi or (self.system_dpi() if self.system_dpi else 0) or 96
            return self.metrics_for_dpi(_SM_CXSMICON, dpi), self.metrics_for_dpi(_SM_CYSMICON, dpi)
        return self.metrics(_SM_CXSMICON), self.metrics(_SM_CYSMICON)


def _short_text(value: str, capacity: int) -> str:
    encoded = value.replace("\0", "").encode("utf-16-le")
    return encoded[: (capacity - 1) * 2].decode("utf-16-le", errors="ignore")


class TrayIcon:
    def __init__(self, open_window, exit_app, next_notice, open_adventure, open_widgets, open_notice, notice_event,
                 *, language=None, icon_path=None):
        self._windows = _Windows()
        self._menu = [(f"打开 {APP_NAME}", "Open Gao Savings", open_window)]
        if open_adventure is not None:
            self._menu.append(("勇者冒险", "Adventure", open_adventure))
        if open_widgets is not None:
            self._menu.append(("桌面小组件", "Desktop widgets", open_widgets))
        self._menu.append(("退出", "Exit", exit_app))
        self._language = language
        self._icon_path = icon_path
        self._next_notice = next_notice
        self._open_notice = open_notice or open_window
        self._notice_event = notice_event
        self._notice_queue = queue.SimpleQueue()
        self._callback = _wndproc(self._window_message)
        self._thread = threading.Thread(target=self._run, name="gaojixu-tray", daemon=True)
        self._ready = threading.Event()
        self._closing = threading.Event()
        self._window = None
        self._icon = None
        self._icon_size = None
        self._owns_icon = False
        self._registered = False
        self._modern_events = False
        self._tracking_menu = False
        self._last_activation = float("-inf")
        self._last_menu_closed = float("-inf")
        self._taskbar_created = self._windows.register_message("TaskbarCreated")

    def close(self) -> None:
        self._closing.set()
        window = self._window
        if window:
            self._windows.post_message(window, _WM_CLOSE, 0, 0)
        if self._thread is not threading.current_thread() and self._thread.ident is not None:
            self._thread.join(timeout=3)

    def _english(self) -> bool:
        choice = self._language() if self._language else "zh"
        if choice == "system":
            choice = locale.getlocale()[0]
        return str(choice).lower().replace("-", "_").split("_", 1)[0] == "en"

    def _icon_data(self, window) -> _NotifyIconData:
        data = _NotifyIconData()
        data.size = ctypes.sizeof(data)
        data.window = window
        data.identifier = _ICON_ID
        return data

    def _attach(self, window, *, dpi_hint=0, refresh=False) -> None:
        api = self._windows
        size = api.tray_icon_size(window, dpi_hint)
        changed = self._icon is None or size != self._icon_size
        if refresh and self._registered and not changed:
            return
        icon, owned = self._load_app_icon(size) if changed else (self._icon, self._owns_icon)
        data = self._icon_data(window)
        data.flags = _NIF_MESSAGE | _NIF_ICON | _NIF_TIP | _NIF_SHOWTIP
        data.message = _WM_TRAY
        data.icon = icon
        data.tip = APP_NAME
        if not (refresh and self._registered and api.notify(_NIM_MODIFY, ctypes.byref(data))):
            # A TaskbarCreated broadcast can mean that Explorer restarted or just changed DPI.
            self._modern_events = False
            self._registered = bool(api.notify(_NIM_ADD, ctypes.byref(data)))
            if not self._registered:
                self._registered = bool(api.notify(_NIM_MODIFY, ctypes.byref(data)))
            if self._registered:
                version = self._icon_data(window)
                version.version = 4
                self._modern_events = bool(api.notify(_NIM_SETVERSION, ctypes.byref(version)))
        if changed and (self._registered or self._icon is None):
            self._release_icon()
            self._icon, self._icon_size, self._owns_icon = icon, size, owned
        elif changed and owned:
            api.destroy_icon(icon)

    def _poll_notice(self, window) -> None:
        if not self._registered or self._next_notice is None:
            return
        notice = self._next_notice()
        if notice is not None:
            title, body, *submitted = notice
            if self._submit(window, title, body) and submitted:
                submitted[0]()

    def _submit(self, window, title, body) -> bool:
        if not self._registered:
            return False
        data = self._icon_data(window)
        data.flags = _NIF_INFO
        data.info_flags = _NIIF_INFO | _NIIF_RESPECT_QUIET_TIME
        data.title = _short_text(title, 64)
        data.body = _short_text(body, 256)
        sent = bool(self._windows.notify(_NIM_MODIFY, ctypes.byref(data)))
        if self._notice_event:
            self._notice_event("submitted" if sent else "rejected")
        return sent

    def test_notification(self, title, body) -> bool:
        window = self._window
        if not window or self._closing.is_set():
            return False
        if self._thread is threading.current_thread():
            return self._submit(window, title, body)
        done = threading.Event()
        result = []
        self._notice_queue.put((title, body, done, result))
        if not self._windows.post_message(window, _WM_NOTICE, 0, 0):
            return False
        return done.wait(timeout=1.5) and result[0]

    def _menu_position(self, window):
        icon = _NotifyIconIdentifier(size=ctypes.sizeof(_NotifyIconIdentifier), window=window, identifier=_ICON_ID)
        rectangle = win.RECT()
        if self._windows.icon_rect(ctypes.byref(icon), ctypes.byref(rectangle)) == 0:
            return (rectangle.left + rectangle.right) // 2, (rectangle.top + rectangle.bottom) // 2
        position = win.POINT()
        self._windows.cursor_position(ctypes.byref(position))
        return position.x, position.y

    def _show_menu(self, window) -> None:
        # A single press can send both WM_RBUTTONUP and WM_CONTEXTMENU.
        if self._tracking_menu or time.monotonic() - self._last_menu_closed < _CLICK_INTERVAL:
            return
        api = self._windows
        menu = api.create_menu()
        if not menu:
            return
        self._tracking_menu = True
        try:
            english = self._english()
            for command, (chinese_label, english_label, _) in enumerate(self._menu, 1):
                api.add_menu_item(menu, 0, command, english_label if english else chinese_label)
            x, y = self._menu_position(window)
            api.foreground(window)
            flags = _TPM_RIGHTBUTTON | _TPM_NONOTIFY | _TPM_RETURNCMD
            selected = api.track_menu(menu, flags, x, y, 0, window, None)
            api.post_message(window, _WM_NULL, 0, 0)
        finally:
            self._tracking_menu = False
            self._last_menu_closed = time.monotonic()
            api.destroy_menu(menu)
            if self._closing.is_set() and self._window:
                api.destroy_window(window)
        if self._closing.is_set():
            return
        if 1 <= selected <= len(self._menu):
            self._menu[selected - 1][2]()
        else:
            api.notify(_NIM_SETFOCUS, ctypes.byref(self._icon_data(window)))

    def _activate(self) -> None:
        now = time.monotonic()
        # Shell versions can report a single click as both a mouse release and NIN_SELECT.
        if now - self._last_activation >= _CLICK_INTERVAL:
            self._last_activation = now
            self._menu[0][2]()

    def _window_message(self, window, message, wparam, lparam):
        try:
            if message == _WM_CLOSE:
                self._closing.set()
                if self._tracking_menu:
                    self._windows.end_menu()
                else:
                    self._windows.destroy_window(window)
                return 0
            if message == _WM_DESTROY:
                self._windows.kill_timer(window, _TRAY_TIMER)
                self._windows.notify(_NIM_DELETE, ctypes.byref(self._icon_data(window)))
                self._registered = False
                self._window = None
                self._windows.post_quit(0)
                return 0
            if message == _WM_TRAY:
                if self._closing.is_set():
                    return 0
                event = lparam & 0xFFFF
                notice_events = {
                    _NIN_BALLOONSHOW: "shown", _NIN_BALLOONHIDE: "hidden",
                    _NIN_BALLOONTIMEOUT: "timed-out", _NIN_BALLOONUSERCLICK: "clicked",
                }
                if event in notice_events and self._notice_event:
                    self._notice_event(notice_events[event])
                if event == _NIN_BALLOONUSERCLICK:
                    self._open_notice()
                elif event in {_NIN_SELECT, _NIN_KEYSELECT, _WM_LBUTTONUP}:
                    self._activate()
                elif event in {_WM_CONTEXTMENU, _WM_RBUTTONUP}:
                    self._show_menu(window)
                return 0
            if message == _WM_NOTICE:
                title, body, done, result = self._notice_queue.get_nowait()
                try:
                    result.append(not self._closing.is_set() and self._submit(window, title, body))
                finally:
                    if not result:
                        result.append(False)
                    done.set()
                return 0
            if message == _WM_TIMER and wparam == _TRAY_TIMER:
                if not self._closing.is_set():
                    if not self._registered:
                        self._attach(window)
                    self._poll_notice(window)
                return 0
            if self._taskbar_created and message == self._taskbar_created:
                if not self._closing.is_set():
                    self._attach(window)
                return 0
            if message in {_WM_DPICHANGED, _WM_DISPLAYCHANGE}:
                if not self._closing.is_set():
                    dpi = wparam & 0xFFFF if message == _WM_DPICHANGED else 0
                    self._attach(window, dpi_hint=dpi, refresh=True)
                return 0
        except Exception:
            _log.exception("Windows notification area callback failed")
        return self._windows.default_procedure(window, message, wparam, lparam)

    def _load_app_icon(self, size):
        api = self._windows
        if self._icon_path:
            from_file = api.load_image(
                None, os.fspath(self._icon_path), _IMAGE_ICON,
                *size, _LR_LOADFROMFILE,
            )
            if from_file:
                return from_file, True
        embedded = win.HICON()
        # SHDefExtractIconW expects the requested width in the low word for its first output.
        api.extract_icon(sys.executable, 0, 0, ctypes.byref(embedded), None, size[0])
        if embedded.value:
            return embedded.value, True
        return api.load_icon(None, 32512), False

    def _release_icon(self):
        if self._icon and self._owns_icon:
            self._windows.destroy_icon(self._icon)
        self._icon, self._icon_size, self._owns_icon = None, None, False

    def _run(self) -> None:
        api = self._windows
        if api.set_thread_dpi_context and not api.set_thread_dpi_context(_PER_MONITOR_AWARE_V2):
            api.set_thread_dpi_context(_PER_MONITOR_AWARE)
        instance = api.module_handle(None)
        class_name = f"GaoJiXuNotificationArea_{os.getpid()}_{threading.get_ident()}"
        window_class = _WindowClass(procedure=self._callback, instance=instance, name=class_name)
        registered_class = api.register_class(ctypes.byref(window_class))
        if not registered_class:
            self._ready.set()
            return
        try:
            self._window = api.create_window(0, class_name, APP_NAME, 0, 0, 0, 0, 0, None, None, instance, None)
            if not self._window:
                return
            if self._closing.is_set():
                return
            self._attach(self._window)
            api.set_timer(self._window, _TRAY_TIMER, 30_000, None)
            api.post_message(self._window, _WM_TIMER, _TRAY_TIMER, 0)
            self._ready.set()
            message = win.MSG()
            while api.get_message(ctypes.byref(message), None, 0, 0) > 0:
                api.dispatch_message(ctypes.byref(message))
        finally:
            self._closing.set()
            if self._window:
                api.destroy_window(self._window)
            self._window = None
            while not self._notice_queue.empty():
                _, _, done, result = self._notice_queue.get_nowait()
                result.append(False)
                done.set()
            self._release_icon()
            api.unregister_class(class_name, instance)
            self._ready.set()


def start_tray(
    open_window: Callable[[], None],
    exit_app: Callable[[], None],
    next_notice: Callable[[], tuple[str, str] | tuple[str, str, Callable[[], None]] | None] | None = None,
    *,
    open_adventure: Callable[[], None] | None = None,
    open_widgets: Callable[[], None] | None = None,
    open_notice: Callable[[], None] | None = None,
    notice_event: Callable[[str], None] | None = None,
    language: Callable[[], str] | None = None,
    icon_path: str | os.PathLike[str] | None = None,
) -> TrayIcon | None:
    """Start a background Win32 message pump. Callbacks should return promptly."""
    if sys.platform != "win32":
        return None
    try:
        tray = TrayIcon(
            open_window, exit_app, next_notice, open_adventure, open_widgets, open_notice, notice_event,
            language=language, icon_path=icon_path,
        )
    except (AttributeError, OSError):
        _log.exception("Windows notification area is unavailable")
        return None
    tray._thread.start()
    if tray._ready.wait(timeout=2) and not tray._window:
        return None
    return tray
