"""Keep Chromium windows in a job owned by the graphical app instance."""

from __future__ import annotations

import ctypes
from ctypes import wintypes as win
import logging
import subprocess
import tempfile
import threading
import time
from pathlib import Path

_log = logging.getLogger(__name__)


class _StartupInfo(ctypes.Structure):
    _fields_ = [
        ("size", win.DWORD), ("reserved", win.LPWSTR), ("desktop", win.LPWSTR), ("title", win.LPWSTR),
        ("x", win.DWORD), ("y", win.DWORD), ("width", win.DWORD), ("height", win.DWORD),
        ("chars_x", win.DWORD), ("chars_y", win.DWORD), ("fill", win.DWORD), ("flags", win.DWORD),
        ("show", win.WORD), ("extra_bytes", win.WORD), ("extra", ctypes.c_void_p),
        ("stdin", win.HANDLE), ("stdout", win.HANDLE), ("stderr", win.HANDLE),
    ]


class _ProcessInfo(ctypes.Structure):
    _fields_ = [("process", win.HANDLE), ("thread", win.HANDLE), ("pid", win.DWORD), ("tid", win.DWORD)]


class _JobLimits(ctypes.Structure):
    _fields_ = [
        ("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64), ("flags", win.DWORD),
        ("min_working_set", ctypes.c_size_t), ("max_working_set", ctypes.c_size_t),
        ("active_processes", win.DWORD), ("affinity", ctypes.c_size_t),
        ("priority", win.DWORD), ("scheduling", win.DWORD),
    ]


class _ExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("basic", _JobLimits), ("io_counts", ctypes.c_uint64 * 6),
        ("memory_limits_and_peaks", ctypes.c_size_t * 4),
    ]


class _JobAccounting(ctypes.Structure):
    _fields_ = [
        ("timings", ctypes.c_int64 * 4), ("page_faults", win.DWORD), ("total", win.DWORD),
        ("active", win.DWORD), ("terminated", win.DWORD),
    ]


class BrowserJob:
    def __init__(self):
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)

        def bind(name, restype, *args):
            fn = getattr(kernel, name)
            fn.restype, fn.argtypes = restype, args
            return fn

        self._close = bind("CloseHandle", win.BOOL, win.HANDLE)
        self._create = bind(
            "CreateProcessW", win.BOOL, win.LPCWSTR, win.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
            win.BOOL, win.DWORD, ctypes.c_void_p, win.LPCWSTR, ctypes.POINTER(_StartupInfo), ctypes.POINTER(_ProcessInfo),
        )
        self._assign = bind("AssignProcessToJobObject", win.BOOL, win.HANDLE, win.HANDLE)
        self._resume = bind("ResumeThread", win.DWORD, win.HANDLE)
        self._kill_process = bind("TerminateProcess", win.BOOL, win.HANDLE, win.UINT)
        self._kill_job = bind("TerminateJobObject", win.BOOL, win.HANDLE, win.UINT)
        self._wait = bind("WaitForSingleObject", win.DWORD, win.HANDLE, win.DWORD)
        self._query = bind("QueryInformationJobObject", win.BOOL, win.HANDLE, ctypes.c_int,
                           ctypes.c_void_p, win.DWORD, ctypes.c_void_p)
        create_job = bind("CreateJobObjectW", win.HANDLE, ctypes.c_void_p, win.LPCWSTR)
        set_limits = bind("SetInformationJobObject", win.BOOL, win.HANDLE, ctypes.c_int, ctypes.c_void_p, win.DWORD)
        self._job = create_job(None, None)
        if not self._job:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = _ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not set_limits(self._job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error())
            self._close(self._job)
            raise error
        try:
            self._profile = tempfile.TemporaryDirectory(prefix="GaoJiXu-Chromium-")
        except OSError:
            self._close(self._job)
            raise
        self.profile = Path(self._profile.name)
        self._lock = threading.Lock()
        self._workbenches = {}

    def launch(self, arguments, *, workbench_profile=None, **_options):
        with self._lock:
            if not self._job:
                raise OSError("The desktop browser job is closed.")
            self._release_finished_launches()
            self._start_process(arguments, workbench_profile)

    def workbench_running(self, profile):
        with self._lock:
            process = self._workbenches.get(profile)
            return bool(process and self._wait(process, 0) == 258)  # WAIT_TIMEOUT

    def _start_process(self, arguments, workbench_profile):
        command = ctypes.create_unicode_buffer(subprocess.list2cmdline(arguments))
        startup = _StartupInfo(size=ctypes.sizeof(_StartupInfo))
        process = _ProcessInfo()
        # The browser must join before its first instruction so all children inherit ownership.
        if not self._create(arguments[0], command, None, None, False, 4, None, None, startup, process):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not self._assign(self._job, process.process) or self._resume(process.thread) == 0xFFFFFFFF:
                error = ctypes.WinError(ctypes.get_last_error())
                self._kill_process(process.process, 1)
                raise error
            if workbench_profile is not None:
                self._workbenches[workbench_profile] = process.process
                process.process = None
        finally:
            self._close(process.thread)
            if process.process:
                self._close(process.process)

    def _release_finished_launches(self):
        for path, process in list(self._workbenches.items()):
            if self._wait(process, 0) == 0:  # WAIT_OBJECT_0
                self._close(process)
                del self._workbenches[path]

    def close(self):
        with self._lock:
            if not self._job:
                return
            self._kill_job(self._job, 0)
            deadline = time.monotonic() + 3
            accounting = _JobAccounting()
            while self._query(self._job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None) and accounting.active:
                if time.monotonic() >= deadline:
                    break
                time.sleep(.04)
            self._close(self._job)
            self._job = None
            for process in self._workbenches.values():
                self._close(process)
            self._workbenches.clear()
        # Windows can still hold Chromium's mapped files briefly after the job is empty.
        deadline = time.monotonic() + 5
        while True:
            try:
                self._profile.cleanup()
                return
            except OSError:
                if time.monotonic() >= deadline:
                    _log.warning("Could not remove the temporary Chromium profile", exc_info=True)
                    return
                time.sleep(.1)
