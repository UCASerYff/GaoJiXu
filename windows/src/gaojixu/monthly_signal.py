"""Per-profile Windows wake signal for the receiver-owned monthly data."""

from __future__ import annotations

import hashlib
import os
from contextlib import contextmanager
from pathlib import Path
from threading import Event


def _event_name(directory: Path) -> str:
    key = os.path.normcase(str(directory.resolve())).encode("utf-8")
    return "Local\\GaoJiXu.MonthlyChanged." + hashlib.sha256(key).hexdigest()


def _kernel():
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateEventW.argtypes = (wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.CreateEventW.restype = wintypes.HANDLE
    kernel.OpenEventW.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR)
    kernel.OpenEventW.restype = wintypes.HANDLE
    kernel.SetEvent.argtypes = (wintypes.HANDLE,)
    kernel.SetEvent.restype = wintypes.BOOL
    kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.restype = wintypes.BOOL
    return kernel


def signal(directory: Path) -> bool:
    """Wake a running receiver in the current Windows session."""
    if os.name != "nt":
        return False
    kernel = _kernel()
    handle = kernel.OpenEventW(0x0002, False, _event_name(directory))  # EVENT_MODIFY_STATE
    if not handle:
        return False
    try:
        return bool(kernel.SetEvent(handle))
    finally:
        kernel.CloseHandle(handle)


@contextmanager
def listener(directory: Path, shutdown: Event):
    if os.name != "nt":
        yield ("poll", lambda: shutdown.wait(1))
        return
    import ctypes
    kernel = _kernel()
    handle = kernel.CreateEventW(None, False, False, _event_name(directory))
    if not handle:
        yield ("poll", lambda: shutdown.wait(1))
        return
    try:
        def wait():
            result = kernel.WaitForSingleObject(handle, 1000)
            if result == 0xFFFFFFFF:
                raise ctypes.WinError(ctypes.get_last_error())
            return result == 0
        yield ("windows-event", wait)
    finally:
        kernel.CloseHandle(handle)
