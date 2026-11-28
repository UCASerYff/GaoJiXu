"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gaojixu.desktop import DesktopSession, RunningInstance, WIDGETS, forward_target, target_for
from gaojixu.errors import AppError
from gaojixu.monthly_signal import signal as signal_monthly_change
from gaojixu.monthly_notices import MonthlyNotices
from gaojixu.native_tray import start_tray
from gaojixu.resources import windows_icon_path
from gaojixu.store import Store, default_data_dir
from gaojixu.version import VERSION_LABEL
from gaojixu.web import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoJiXu", description="搞积蓄 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--create-empty", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--widget-snapshot", action="store_true")
    parser.add_argument("--widget", choices=WIDGETS)
    parser.add_argument("--notify-monthly-change", action="store_true")
    parser.add_argument("link", nargs="?")
    args = parser.parse_args(argv)
    command_line = getattr(sys, "frozen", False) and Path(sys.executable).stem.lower() == "gaojixu-cli"
    if args.version:
        print(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
    if args.notify_monthly_change:
        if not signal_monthly_change(directory):
            print("No GaoJiXu monthly listener in this Windows session. The receiver will check on startup.", file=sys.stderr)
            return 2
        print("monthly-change-signaled")
        return 0
    if args.inspect:
        _print_counts(Store(directory, readonly=True))
        return 0
    try:
        target = target_for(args.link, args.widget)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 2
    instance = RunningInstance(directory)
    if not instance.acquire():
        if command_line or args.no_browser or args.widget_snapshot or args.create_empty:
            print("这份资料已在另一个搞积蓄窗口打开。", file=sys.stderr)
            return 2
        url = instance.running_url()
        if not url:
            print("搞积蓄正在启动，请稍后重试。", file=sys.stderr)
            return 2
        if forward_target(url, target, instance.key):
            return 0
        print("搞积蓄暂时无法打开窗口，请稍后重试。", file=sys.stderr)
        return 2
    try:
        return _run(args, directory, instance, target, graphical=not args.no_browser and not command_line)
    finally:
        instance.close()


def _run(args, directory, instance, target, *, graphical):
    store = Store(directory)
    try:
        if args.create_empty:
            store.create_library()
            if not args.serve:
                print("created")
                return 0
        if args.widget_snapshot:
            if store.status != "ready":
                print(store.notice or store.status, file=sys.stderr)
                return 2
            from gaojixu import widget
            widget.publish(store)
            print("widget-snapshot")
            return 0
    except AppError as exc:
        print(exc.message, file=sys.stderr)
        return 2
    server = serve(store, port=args.port, open_browser=False, instance_key=instance.key)
    tray = None
    try:
        if graphical:
            desktop = server.desktop = DesktopSession(server.url, instance.key)
            server.desktop_widgets = desktop.widgets

            def open_desktop(target=""):
                if not server.shutdown_requested.is_set():
                    desktop.open(target)

            def request_quit():
                if not desktop.main or not desktop.main.request_quit():
                    server.request_shutdown()

            tray = start_tray(
                open_desktop,
                request_quit,
                MonthlyNotices(server).next_notice,
                open_adventure=lambda: open_desktop("#adventure"),
                open_widgets=lambda: open_desktop("#widgets"),
                open_notice=lambda: open_desktop("#fixed-expenses"),
                language=lambda: store.settings.get("language", "system"),
                icon_path=windows_icon_path(),
            )
            server.desktop_tray = tray
        instance.publish(server.server_address[1])
        if graphical:
            desktop.open(target)
            if server.desktop_widgets:
                server.desktop_widgets.restore()
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.request_shutdown()
        try:
            if tray:
                tray.close()
        finally:
            try:
                server.shutdown()
                server.server_close()
            finally:
                if server.desktop:
                    server.desktop.close()
    return 0


def _print_counts(store: Store) -> None:
    print(f"status={store.status}")
    print(f"version={VERSION_LABEL}")
    counts = store.counts()
    for key in ("accounts", "entries", "goals", "records", "level"):
        print(f"{key}={counts.get(key)}")
