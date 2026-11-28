"""Reuse a running local server for launch shortcuts and deep links."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import webbrowser
from pathlib import Path
from urllib.error import URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen

from gaojixu.errors import AppError

_log = logging.getLogger(__name__)
WIDGETS = ("all", "calendar", "net-worth", "expenses", "benefits", "adventure")
ROUTES = {
    "overview": "overview", "ledger": "ledger", "budgets": "budgets", "accounts": "accounts",
    "fixed-income": "fixed-income", "fixed-expenses": "fixed-expenses", "today": "fixed-expenses",
    "benefits": "benefits", "adventure": "adventure", "goals": "goals",
}
TARGETS = {"", "#widgets", *("#" + route for route in ROUTES.values()), *("?widget=" + widget for widget in WIDGETS)}


def target_for(link: str | None, widget: str | None = None) -> str:
    if widget:
        return f"?widget={widget}"
    if link:
        location = urlsplit(link)
        if location.scheme == "gaojixu" and location.netloc in ROUTES and location.path in ("", "/"):
            return "#" + ROUTES[location.netloc]
        if location.scheme == "gaojixu" and location.netloc == "widgets" and location.path in ("", "/"):
            name = parse_qs(location.query).get("type", ["all"])[0]
            if name in WIDGETS:
                return f"?widget={name}"
        raise ValueError("无法识别这个搞积蓄链接。")
    return ""


class RunningInstance:
    def __init__(self, directory: Path):
        data_key = os.path.normcase(str(directory.resolve()))
        self.key = hashlib.sha256(data_key.encode("utf-8")).hexdigest()
        cache = Path(tempfile.gettempdir()) / "GaoJiXu"
        cache.mkdir(parents=True, exist_ok=True)
        self.locator = cache / (self.key + ".port")
        self.lock_path = cache / (self.key + ".lock")
        self.lock = None

    def acquire(self) -> bool:
        self.lock = self.lock_path.open("a+b")
        self.lock.seek(0, os.SEEK_END)
        if self.lock.tell() == 0:
            self.lock.write(b"\0")
            self.lock.flush()
        self.lock.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.lock.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock.close()
            self.lock = None
            return False
        self.locator.unlink(missing_ok=True)
        return True

    def publish(self, port: int):
        temp = self.locator.with_suffix(".port.tmp")
        temp.write_text(str(port), encoding="ascii")
        temp.replace(self.locator)

    def running_url(self) -> str | None:
        for _ in range(25):
            try:
                port = int(self.locator.read_text(encoding="ascii"))
                if 1 <= port <= 65535:
                    url = f"http://127.0.0.1:{port}/"
                    with urlopen(url + "instance", timeout=.25) as response:
                        if response.read(128).decode("ascii") == self.key:
                            return url
            except (OSError, URLError, UnicodeError, ValueError):
                pass
            time.sleep(.12)
        return None

    def close(self):
        if self.lock is not None:
            self.locator.unlink(missing_ok=True)
            self.lock.close()
            self.lock = None


def chromium():
    if os.name != "nt":
        return None
    edge_path = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft/Edge/Application/msedge.exe"
    chrome_path = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Google/Chrome/Application/chrome.exe"
    edge = shutil.which("msedge")
    return next((candidate for candidate in (Path(edge) if edge else edge_path, edge_path, chrome_path) if candidate.is_file()), None)


def open_window(url: str):
    executable = chromium()
    if executable:
        try:
            subprocess.Popen([str(executable), "--app=" + url], close_fds=True)
            return
        except OSError:
            pass
    webbrowser.open(url)


def start_widgets(url, instance_key, *, browser=None, native=None, executable=None):
    executable = executable or chromium()
    if executable is None:
        return None
    from gaojixu.desktop_widgets import DesktopWidgets, WidgetWindows

    base = Path(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()) / "GaoSeries" / "GaoJiXuDesktop" / instance_key
    try:
        options = {"launch": browser.launch, "browser_profile": browser.profile} if browser else {}
        manager = DesktopWidgets(url, base, executable, native or WidgetWindows(), **options)
    except (AttributeError, OSError):
        # Older builds can still show the same widget as an independent browser window.
        return None
    manager.start()
    return manager


class DesktopMain:
    """Activate the workbench window or launch one in the app's own browser job."""

    def __init__(self, url, executable, native, browser):
        self.url, self.native, self.browser = url, native, browser
        self.executable = os.path.normcase(str(Path(executable).resolve()))
        self._lock = threading.Lock()
        self._lease = None
        self._hwnd = None
        self._route = ""
        self._quit = False
        self._profile = None
        self._startup_until = 0.0
        self._closing = threading.Event()
        self._retry = None

    def _sample(self):
        if self._hwnd:
            if self.native.belongs(self._hwnd, self._lease):
                self.native.update_shell_icon(self._hwnd, self._lease)
            else:
                self.native.forget_shell_icon(self._hwnd, self._lease)
                self._hwnd = None
        if self._lease and not self._hwnd:
            self._hwnd = self.native.discover(self._lease, self.executable)
            if self._hwnd:
                self._startup_until = 0.0
            elif time.monotonic() >= self._startup_until and not self.browser.workbench_running(self._profile):
                self._lease = None

    def open(self, target=""):
        with self._lock:
            if self._closing.is_set():
                return
            self._sample()
            if self._lease:
                if target:
                    self._route = target.removeprefix("#")
                if self._hwnd and self.native.visible(self._hwnd):
                    self.native.activate(self._hwnd)
                elif not self._retry or not self._retry.is_alive():
                    # The first window might close while its native handle is still being attached.
                    self._retry = threading.Thread(target=self._finish_open, args=(self._lease,),
                                                   name="gaojixu-workbench-reopen", daemon=True)
                    self._retry.start()
                return
            self._open_new(target)

    def _open_new(self, target):
        lease = secrets.token_hex(16)
        url = self.url + "?" + urlencode({"workbench": lease}) + target
        # A Chromium singleton that is exiting can swallow a launch for its old profile.
        profile = self.browser.profile / ("Workbench-" + lease)
        self.browser.launch([
            self.executable, f"--user-data-dir={profile}", "--no-first-run",
            "--no-default-browser-check", "--disable-background-mode", "--app=" + url,
        ], workbench_profile=profile)
        self._profile, self._lease = profile, lease
        self._startup_until = time.monotonic() + 4
        self._route, self._quit = "", False

    def _finish_open(self, lease):
        while not self._closing.wait(.15):
            with self._lock:
                if self._lease not in {None, lease} or self._closing.is_set():
                    return
                self._sample()
                if self._hwnd and self.native.visible(self._hwnd):
                    self.native.activate(self._hwnd)
                    return
                if self._lease is None:
                    try:
                        self._open_new("#" + self._route if self._route else "")
                    except OSError:
                        _log.warning("Could not reopen the workbench", exc_info=True)
                    return

    def request_quit(self):
        with self._lock:
            self._sample()
            if not self._hwnd or not self.native.visible(self._hwnd):
                return False
            self._quit = True
            self.native.activate(self._hwnd)
            return True

    def events(self, lease):
        with self._lock:
            if not self._lease or self._lease != lease:
                return {}
            self._sample()
            if not self._hwnd:
                return {"attached": False}
            result = {"attached": True, "route": self._route, "quit": self._quit}
            self._route, self._quit = "", False
            return result

    def close(self):
        self._closing.set()
        with self._lock:
            self._sample()
            if self._hwnd:
                self.native.close(self._hwnd)
            self._hwnd, self._lease = None, None
        if self._retry:
            self._retry.join()


class DesktopSession:
    def __init__(self, url, instance_key):
        self.url = url
        self.main = self.widgets = self.browser = self.native = None
        executable = chromium()
        if executable is not None:
            from gaojixu.desktop_browser import BrowserJob
            from gaojixu.desktop_widgets import WidgetWindows

            try:
                native = WidgetWindows()
                self.browser = BrowserJob()
            except (OSError, AttributeError):
                return
            self.native = native
            self.main = DesktopMain(url, executable, native, self.browser)
            self.widgets = start_widgets(url, instance_key, browser=self.browser, native=native, executable=executable)

    def open(self, target=""):
        kind = parse_qs(urlsplit(target).query).get("widget", [None])[0]
        if kind in WIDGETS and kind != "all":
            if self.widgets:
                try:
                    self.widgets.open(kind)
                    return
                except AppError:
                    pass
            webbrowser.open(self.url + target)
            return
        if kind == "all":
            target = "#widgets"
        if self.main:
            try:
                self.main.open(target)
                return
            except OSError:
                pass
        webbrowser.open(self.url + target)

    def close(self):
        try:
            if self.main:
                self.main.close()
            if self.widgets:
                self.widgets.close()
        finally:
            try:
                if self.browser:
                    self.browser.close()
            finally:
                if self.native:
                    self.native.shell_icons.close()


def forward_target(url, target, instance_key):
    try:
        with urlopen(url, timeout=2) as response:
            html = response.read(65536).decode("utf-8")
        token = re.search(r'<meta name="gao-token" content="([A-Za-z0-9_-]+)">', html)
        if token is None:
            return False
        with urlopen(url + "instance", timeout=2) as response:
            if response.read(128).decode("ascii") != instance_key:
                return False
        request = Request(
            url + "api/desktop/open",
            data=json.dumps({"target": target}).encode("utf-8"),
            headers={"Content-Type": "application/json", "X-Gao-Token": token[1]},
        )
        with urlopen(request, timeout=3) as response:
            received = json.load(response)
            return received.get("ok") is True
    except (OSError, URLError, UnicodeError, ValueError):
        return False


def valid_target(target):
    return isinstance(target, str) and target in TARGETS
