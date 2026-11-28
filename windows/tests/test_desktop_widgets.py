import json
from datetime import datetime, timezone
import threading
from types import SimpleNamespace
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from gaojixu import monthly
from gaojixu.desktop import DesktopMain, DesktopSession, forward_target
from gaojixu.desktop_widgets import DesktopWidgets, TYPES
from gaojixu.errors import AppError
from gaojixu.monthly_notices import MonthlyNotices
from gaojixu.store import Store
from gaojixu.web import serve


class TestWindows:
    __test__ = False

    def __init__(self):
        self.windows = {}
        self.pinned = {}
        self.positions = {}
        self.foreground = None

    def discover(self, lease, _executable):
        return self.windows.get(lease)

    def belongs(self, hwnd, lease):
        return self.windows.get(lease) == hwnd

    def update_shell_icon(self, hwnd, lease):
        assert self.belongs(hwnd, lease)

    def forget_shell_icon(self, hwnd, lease):
        assert not self.belongs(hwnd, lease)

    def visible(self, hwnd):
        return hwnd in self.windows.values()

    def topmost(self, hwnd):
        return self.pinned.get(hwnd, False)

    def pin(self, hwnd, requested):
        self.pinned[hwnd] = requested
        return True

    def placement(self, hwnd):
        return self.positions[hwnd]

    def restore(self, hwnd, rect):
        self.positions[hwnd] = rect

    def activate(self, hwnd):
        self.foreground = hwnd

    def close(self, hwnd):
        lease = next(lease for lease, handle in self.windows.items() if handle == hwnd)
        del self.windows[lease]


def test_workbench_restore_routes_and_quit_in_owned_window(tmp_path):
    windows = TestWindows()
    launches = []
    closed = threading.Event()
    browser = SimpleNamespace(profile=tmp_path / "browser", launch=lambda options, **_kw: launches.append(options),
                              workbench_running=lambda _profile: not closed.is_set())
    main = DesktopMain("http://127.0.0.1:5000/", tmp_path / "chrome.exe", windows, browser)
    main.open()
    first = main._lease
    main.open("#ledger")
    assert len(launches) == 1 and main.events(first) == {"attached": False}
    windows.windows[first] = 8
    main.open()
    assert windows.foreground == 8
    assert main.request_quit()
    assert main.events("unrelated") == {}
    assert main.events(first) == {"attached": True, "route": "ledger", "quit": True}
    assert main.events(first) == {"attached": True, "route": "", "quit": False}
    windows.close(8)
    closed.set()
    assert not main.request_quit()
    main.open("#fixed-expenses")
    assert len(launches) == 2 and main._lease != first
    assert launches[0][1] != launches[1][1]
    assert launches[-1][-1].endswith("#fixed-expenses")
    main.close()


def test_reopen_replaces_closed_workbench_before_hwnd_was_attached(tmp_path):
    launches = []
    closed = threading.Event()
    reopened = threading.Event()

    def launch(options, **_kwargs):
        launches.append(options)
        if len(launches) == 2:
            reopened.set()

    browser = SimpleNamespace(profile=tmp_path / "browser", launch=launch,
                              workbench_running=lambda _profile: not closed.is_set())
    main = DesktopMain("http://127.0.0.1:5000/", tmp_path / "chrome.exe", TestWindows(), browser)
    try:
        main.open()
        main.open("#ledger")
        assert len(launches) == 1
        main._startup_until = 0.0
        closed.set()
        assert reopened.wait(2)
        assert launches[-1][-1].endswith("#ledger")
    finally:
        main.close()


def test_desktop_widget_pin_restore_duplicate_and_close(tmp_path):
    browser = tmp_path / "synthetic-browser.exe"
    windows = TestWindows()
    launches = []
    manager = DesktopWidgets("http://127.0.0.1:5000/", tmp_path / "desktop", browser, windows,
                             launch=lambda options, **_kw: launches.append(options))
    for handle, widget in enumerate(TYPES, 1):
        assert manager.open(widget)["attaching"]
        window = manager._active[widget]
        windows.windows[window.lease] = handle
        windows.positions[handle] = [40 * handle, 35 * handle, 500 + 40 * handle, 400 + 35 * handle]
        assert not manager.request({"command": "status", "widget": widget, "lease": "unknown"}, lambda _: None)["currentAttached"]
        assert manager.request({"command": "status", "widget": widget, "lease": window.lease}, lambda _: None)["currentAttached"]
    assert len(launches) == 4
    kinds = {kind: window.lease for kind, window in manager._active.items()}
    for name in ("calendar", "expenses"):
        request = {"command": "pin", "widget": name, "lease": kinds[name], "pinned": True}
        assert manager.request(request, lambda _: None)["pinned"]
    with pytest.raises(AppError):
        manager.request({"command": "close", "widget": "calendar", "lease": "unknown"}, lambda _: None)
    routes = []
    manager.request({"command": "route", "widget": "expenses", "lease": kinds["expenses"]}, routes.append)
    assert routes == ["fixed-expenses"]
    assert manager.open("calendar")["open"] and windows.foreground == 1 and len(launches) == 4
    manager.request({"command": "close", "widget": "expenses", "lease": kinds["expenses"]}, lambda _: None)
    manager.close()
    assert not windows.windows

    restarted = DesktopWidgets(manager.url, manager.base, browser, windows, launch=lambda args, **_kw: launches.append(args))
    restarted.restore()
    assert list(restarted._active) == ["calendar"]
    assert "--start-minimized" in launches[-1]
    lease = restarted._active["calendar"].lease
    windows.windows[lease] = 99
    windows.positions[99] = [0, 0, 200, 200]
    status = restarted.request({"command": "status", "widget": "calendar", "lease": lease}, lambda _: None)
    assert status["windows"]["calendar"]["pinned"]
    assert windows.positions[99] == [40, 35, 540, 435]
    assert not restarted.request({"command": "pin", "widget": "calendar", "lease": lease, "pinned": False}, lambda _: None)["pinned"]
    restarted.close()


def test_desktop_layout_future_version_preserved(tmp_path):
    layout = tmp_path / "layout.json"
    original = '{"version": 70, "windows": {"calendar": {}}}'
    layout.write_text(original, encoding="utf-8")
    windows = TestWindows()
    manager = DesktopWidgets("http://127.0.0.1:5000/", tmp_path, "chrome.exe", windows, launch=lambda *_a, **_kw: None)
    manager.open("calendar")
    lease = manager._active["calendar"].lease
    windows.windows[lease] = 1
    windows.positions[1] = [40, 40, 440, 440]
    manager.request({"command": "pin", "widget": "calendar", "lease": lease, "pinned": True}, lambda _: None)
    manager.close()
    assert layout.read_text(encoding="utf-8") == original


def test_desktop_api_auth_secondary_launch_and_notification(tmp_path, monkeypatch):
    store = Store(tmp_path / "synthetic-data")
    server = serve(store, open_browser=False, instance_key="profile-id")
    windows = TestWindows()
    launches = []
    manager = DesktopWidgets(server.url, tmp_path / "widgets", "chrome.exe", windows,
                             launch=lambda args, **_kw: launches.append(args))
    server.desktop_widgets = manager
    monkeypatch.setattr("gaojixu.desktop.chromium", lambda: None)
    server.desktop = DesktopSession(server.url, server.instance_key)
    server.desktop.widgets = manager
    notifications = []

    class Tray:
        def test_notification(self, title, body):
            notifications.append((title, body))
            return True

    server.desktop_tray = Tray()
    monkeypatch.setattr("gaojixu.desktop.open_window", lambda url: pytest.fail("Unexpected unmanaged window " + url))

    def post(path, data, token):
        request = Request(
            server.url + path, data=json.dumps(data).encode(),
            headers={"Content-Type": "application/json", "X-Gao-Token": token},
        )
        with urlopen(request, timeout=2) as response:
            return json.load(response)

    try:
        with pytest.raises(HTTPError) as error:
            post("api/desktop/widgets", {"command": "open", "widget": "calendar"}, "bogus")
        assert error.value.code == 403
        assert not forward_target(server.url, "?widget=expenses", "another-profile")
        assert not forward_target(server.url, "?widget=expenses#unknown", server.instance_key)
        assert not forward_target(server.url, "?widget=benefits", server.instance_key)
        assert not launches
        assert forward_target(server.url, "?widget=expenses", server.instance_key)
        assert len(launches) == 1 and "widget=expenses" in launches[0][-1]
        assert {"submitted": True} == post("api/desktop/notification-test", {"language": "en"}, server.token)["result"]
        assert notifications[0][0] == "Gao Savings · Notification test"
        with pytest.raises(HTTPError) as error:
            post("api/desktop/notification-test", {"language": "en"}, server.token)
        assert error.value.code == 400
        server.desktop_tray = None
        for language, expected in [("en", "Windows did not accept the notification."), ("zh", "Windows 未接受通知。")]:
            server.last_test_notice = float("-inf")
            with pytest.raises(HTTPError) as failure:
                post("api/desktop/notification-test", {"language": language}, server.token)
            assert json.load(failure.value)["error"] == expected
    finally:
        manager.close()
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()


def test_prior_layout_ignores_retired_benefits_widget(tmp_path):
    layout = tmp_path / "layout.json"
    position = {"open": True, "pinned": True, "rect": [40, 40, 440, 440]}
    original = {"version": 1, "windows": {"benefits": position, "expenses": position}}
    layout.write_text(json.dumps(original), encoding="utf-8")
    launches = []
    manager = DesktopWidgets("http://127.0.0.1:5000/", tmp_path, "chrome.exe", TestWindows(),
                             launch=lambda options, **_kw: launches.append(options))
    try:
        manager.restore()
        status = manager.request({"command": "status"}, lambda _: None)
        assert set(status["windows"]) == {"calendar", "net-worth", "expenses", "adventure"}
        assert len(launches) == 1 and "widget=expenses" in launches[0][-1]
    finally:
        manager.close()


def test_unsubmitted_reminder_is_resampled_after_privacy_change(tmp_path):
    now = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)
    store = Store(tmp_path, tz=timezone.utc, now=lambda: now)
    store.create_library()
    store.create_monthly()
    monthly.update_preferences(tmp_path, {"notifications": True, "privacy": False}, store.now)
    monthly.save_event(tmp_path, {"name": "Synthetic private data", "deadline": "2026-11-27T09:30"}, store.now)
    reminders = MonthlyNotices(SimpleNamespace(store=store, lock=threading.Lock()))
    assert reminders.next_notice()[1] == "Synthetic private data"
    monthly.update_preferences(tmp_path, {"privacy": True}, store.now)
    _, message, submitted = reminders.next_notice()
    assert message == "有到期事项待处理。"
    submitted()
    assert reminders.next_notice() is None
