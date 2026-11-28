"""Set shell identity and DPI-sized icons on the app's owned Chromium windows."""

from __future__ import annotations

import ctypes as ct
from ctypes import wintypes as win
import threading
import time
from uuid import UUID

from gaojixu.resources import windows_icon_path
from gaojixu.version import APP_USER_MODEL_ID


class _Guid(ct.Structure):
    _fields_ = [("data1", ct.c_uint32), ("data2", ct.c_uint16), ("data3", ct.c_uint16),
                ("data4", ct.c_uint8 * 8)]


class _PropertyKey(ct.Structure):
    _fields_ = [("guid", _Guid), ("pid", win.DWORD)]


class _PropertyValue(ct.Structure):
    # The trailing fields cover the PROPVARIANT union, including its x64 vector form.
    _fields_ = [("vt", win.WORD), ("reserved", win.WORD * 3),
                ("pointer", ct.c_void_p), ("padding", ct.c_void_p)]


def _guid(value: str) -> _Guid:
    return _Guid.from_buffer_copy(UUID(value).bytes_le)


_PROPERTY_STORE = _guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")
_APP_ID = _PropertyKey(_guid("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3"), 5)


class WindowIcons:
    def __init__(self):
        user = ct.WinDLL("user32", use_last_error=True)
        shell = ct.WinDLL("shell32", use_last_error=True)
        ole = ct.WinDLL("ole32", use_last_error=True)

        def bind(dll, name, restype, *args):
            fn = getattr(dll, name)
            fn.restype, fn.argtypes = restype, args
            return fn

        self._window_dpi = bind(user, "GetDpiForWindow", win.UINT, win.HWND)
        self._metric = bind(user, "GetSystemMetricsForDpi", ct.c_int, ct.c_int, win.UINT)
        self._load = bind(user, "LoadImageW", win.HANDLE, win.HINSTANCE, win.LPCWSTR, win.UINT,
                          ct.c_int, ct.c_int, win.UINT)
        self._destroy = bind(user, "DestroyIcon", win.BOOL, win.HICON)
        self._send = bind(user, "SendMessageTimeoutW", win.LPARAM, win.HWND, win.UINT, win.WPARAM,
                          win.LPARAM, win.UINT, win.UINT, ct.POINTER(ct.c_size_t))
        self._property_store = bind(shell, "SHGetPropertyStoreForWindow", ct.c_long, win.HWND,
                                    ct.POINTER(_Guid), ct.POINTER(ct.c_void_p))
        self._co_init = bind(ole, "CoInitializeEx", ct.c_long, ct.c_void_p, win.DWORD)
        self._co_done = bind(ole, "CoUninitialize", None)
        self._clear_value = bind(ole, "PropVariantClear", ct.c_long, ct.POINTER(_PropertyValue))
        self._lock = threading.Lock()
        self._path = str(windows_icon_path())
        self._icons = {}
        self._windows = {}

    def _set_app_id(self, hwnd, app_id):
        initialized = self._co_init(None, 2)  # COINIT_APARTMENTTHREADED
        if initialized < 0 and initialized & 0xffffffff != 0x80010106:  # RPC_E_CHANGED_MODE
            return False
        store = ct.c_void_p()
        try:
            if self._property_store(hwnd, ct.byref(_PROPERTY_STORE), ct.byref(store)) < 0 or not store.value:
                return False
            table = ct.cast(store, ct.POINTER(ct.POINTER(ct.c_void_p)))[0]
            release = ct.WINFUNCTYPE(win.ULONG, ct.c_void_p)(table[2])
            get_value = ct.WINFUNCTYPE(ct.c_long, ct.c_void_p, ct.POINTER(_PropertyKey),
                                     ct.POINTER(_PropertyValue))(table[5])
            set_value = ct.WINFUNCTYPE(ct.c_long, ct.c_void_p, ct.POINTER(_PropertyKey),
                                     ct.POINTER(_PropertyValue))(table[6])
            try:
                previous = _PropertyValue()
                current = None
                try:
                    if get_value(store, ct.byref(_APP_ID), ct.byref(previous)) >= 0 and previous.vt == 31 and previous.pointer:
                        current = ct.wstring_at(previous.pointer)
                finally:
                    self._clear_value(ct.byref(previous))
                if current == app_id or (app_id is None and current != APP_USER_MODEL_ID):
                    return True
                value = _PropertyValue()  # VT_EMPTY removes the property from a closing window.
                if app_id:
                    buffer = ct.create_unicode_buffer(app_id)
                    value.vt = 31  # VT_LPWSTR
                    value.pointer = ct.addressof(buffer)
                return set_value(store, ct.byref(_APP_ID), ct.byref(value)) >= 0
            finally:
                release(store)
        finally:
            if initialized >= 0:
                self._co_done()

    def _icon(self, width, height):
        key = (width, height)
        if key not in self._icons:
            loaded = self._load(None, self._path, 1, width, height, 0x10)  # IMAGE_ICON, LR_LOADFROMFILE
            if loaded:
                self._icons[key] = loaded
        return self._icons.get(key)

    def _message(self, hwnd, message, kind, value):
        result = ct.c_size_t()
        if self._send(hwnd, message, kind, value, 0x22, 100, ct.byref(result)):
            return result.value
        return None

    def apply(self, hwnd, lease):
        with self._lock:
            dpi = self._window_dpi(hwnd)
            if not dpi:
                return
            now = time.monotonic()
            state = self._windows.get(hwnd)
            is_current = state and state[:2] == (lease, dpi)
            if is_current and now < state[3]:
                return
            # Use window DPI because Chromium can move between monitors while it stays open.
            for kind, x, y in ((0, 49, 50), (1, 11, 12)):  # ICON_SMALL, ICON_BIG
                width, height = self._metric(x, dpi), self._metric(y, dpi)
                if width > 0 and height > 0:
                    icon = self._icon(width, height)
                    if icon and self._message(hwnd, 0x7F, kind, dpi) != icon:  # WM_GETICON
                        self._message(hwnd, 0x80, kind, icon)  # WM_SETICON
            self._set_app_id(hwnd, APP_USER_MODEL_ID)
            started = state[2] if is_current else now
            # Chromium can replace its initial window properties after favicon loading.
            # Recheck via the existing HWND sampling, without a second polling timer.
            self._windows[hwnd] = (lease, dpi, started, now + (0 if now - started < 4 else 3))

    def forget(self, hwnd, lease):
        with self._lock:
            state = self._windows.get(hwnd)
            if state and state[0] == lease:
                del self._windows[hwnd]

    def ungroup(self, hwnd):
        with self._lock:
            if self._windows.pop(hwnd, None):
                self._set_app_id(hwnd, None)

    def close(self):
        # The owner terminates the Chromium job before dropping shared window icon handles.
        with self._lock:
            for icon in self._icons.values():
                self._destroy(icon)
            self._icons.clear()
            self._windows.clear()
