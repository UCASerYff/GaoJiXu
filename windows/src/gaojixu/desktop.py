"""Reuse a running local server for launch shortcuts and deep links."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import time
import webbrowser
from pathlib import Path
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen

WIDGETS = ("all", "calendar", "net-worth", "expenses", "benefits", "adventure")
ROUTES = {
    "overview": "overview", "ledger": "ledger", "budgets": "budgets", "accounts": "accounts",
    "fixed-income": "fixed-income", "fixed-expenses": "fixed-expenses", "today": "fixed-expenses",
    "benefits": "benefits", "adventure": "adventure", "goals": "goals",
}


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


def open_window(url: str):
    if os.name == "nt":
        edge_path = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Microsoft/Edge/Application/msedge.exe"
        chrome_path = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Google/Chrome/Application/chrome.exe"
        executable = shutil.which("msedge") or next((candidate for candidate in (edge_path, chrome_path) if candidate.is_file()), None)
        if executable:
            try:
                subprocess.Popen([str(executable), "--app=" + url], close_fds=True)
                return
            except OSError:
                pass
    webbrowser.open(url)
