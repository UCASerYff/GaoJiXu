"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gaojixu.desktop import RunningInstance, WIDGETS, open_window, target_for
from gaojixu.errors import AppError
from gaojixu.monthly_notices import MonthlyNotices
from gaojixu.native_tray import start_tray
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
    parser.add_argument("link", nargs="?")
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
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
        if args.no_browser or args.widget_snapshot or args.create_empty:
            print("这份资料已在另一个搞积蓄窗口打开。", file=sys.stderr)
            return 2
        url = instance.running_url()
        if not url:
            print("搞积蓄正在启动，请稍后重试。", file=sys.stderr)
            return 2
        open_window(url + target)
        return 0
    try:
        return _run(args, directory, instance, target)
    finally:
        instance.close()


def _run(args, directory, instance, target):
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
        instance.publish(server.server_address[1])
        if not args.no_browser:
            tray = start_tray(
                lambda: open_window(server.url),
                server.shutdown_requested.set,
                MonthlyNotices(server).next_notice,
                open_adventure=lambda: open_window(server.url + "#adventure"),
            )
            open_window(server.url + target)
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        if tray:
            tray.close()
        server.server_close()
    return 0


def _print_counts(store: Store) -> None:
    print(f"status={store.status}")
    print(f"version={VERSION_LABEL}")
    counts = store.counts()
    for key in ("accounts", "entries", "goals", "records", "level"):
        print(f"{key}={counts.get(key)}")
