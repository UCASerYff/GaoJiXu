"""只监听 127.0.0.1 的本地页面。个人资料不离开这台电脑。"""

from __future__ import annotations

import json
import mimetypes
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from gaojixu import adventure, adventure_view, csv_review, csvutil, finance, finance_views, monthly, monthly_bridge
from gaojixu.desktop import open_window, valid_target
from gaojixu.errors import AppError
from gaojixu.monthly_integration import MonthlyIntegration
from gaojixu.resources import asset_dir, mac_asset_dir
from gaojixu.store import Store
from gaojixu.version import VERSION_LABEL


class SavingsServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = False

    def __init__(self, store: Store, host: str = "127.0.0.1", port: int = 0, instance_key: str = ""):
        self.store = store
        self.token = secrets.token_urlsafe(24)
        self.instance_key = instance_key
        self.lock = threading.Lock()
        self.desktop = None
        self.desktop_widgets = None
        self.desktop_tray = None
        self.last_test_notice = float("-inf")
        self.shutdown_requested = threading.Event()
        self.battle_thread = None
        self.monthly_integration = MonthlyIntegration(store, self.lock, self.shutdown_requested)
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"

    def request_shutdown(self) -> None:
        self.shutdown_requested.set()

    def server_close(self) -> None:
        self.request_shutdown()
        super().server_close()
        monthly_thread = self.monthly_integration.thread
        if monthly_thread.is_alive():
            monthly_thread.join()
        if self.battle_thread and self.battle_thread.is_alive():
            self.battle_thread.join()


class Handler(BaseHTTPRequestHandler):
    server: SavingsServer
    timeout = 5

    def do_GET(self) -> None:
        if not self._valid_host():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/instance" and self.server.instance_key:
            self._bytes(self.server.instance_key.encode("ascii"), "text/plain; charset=utf-8")
            return
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/desktop/events":
            if self._authorized():
                desktop = self.server.desktop
                lease = parse_qs(parsed.query).get("lease", [""])[0]
                self._json(desktop.main.events(lease) if desktop and desktop.main else {})
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                result = self.server.store.snapshot()
                result["monthlyIntegration"] = self.server.monthly_integration.state
            self._json(result)
            return
        if parsed.path == "/api/monthly/integration":
            if self._authorized():
                self._json(self.server.monthly_integration.state)
            return
        if parsed.path == "/api/adventure/state":
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    store = self.server.store
                    adventure_data = store.adventure_snapshot()
                    resources = {key: store.doc["adventure"].get(key) for key in ("coins", "tickets", "stardust", "insight", "level")}
                self._json({"adventure": adventure_data, "resources": resources})
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
            return
        if parsed.path == "/api/finance/view":
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    result = finance_views.view(self.server.store, parse_qs(parsed.query))
                self._json(result)
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
            return
        if parsed.path in {"/api/csv/review", "/api/csv/review/detail"}:
            if not self._authorized():
                return
            try:
                with self.server.lock:
                    if parsed.path == "/api/csv/review":
                        result = csv_review.list_batches(self.server.store)
                    else:
                        batch_id = parse_qs(parsed.query).get("batchID", [""])[0]
                        result = csv_review.detail(self.server.store, batch_id)
                self._json(result)
            except AppError as exc:
                self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
            return
        if parsed.path == "/api/catalog":
            if not self._authorized():
                return
            query = parse_qs(parsed.query)
            kind = query.get("kind", ["equipment"])[0]
            text = query.get("q", [""])[0]
            slot = query.get("slot", [""])[0]
            self._json({"items": self.server.store.search_catalog(kind, text, slot)})
            return
        if parsed.path in {"/api/adventure/catalog", "/api/adventure/gear-details"}:
            if not self._authorized():
                return
            query = parse_qs(parsed.query)
            try:
                with self.server.lock:
                    self.server.store.require_ready()
                    if parsed.path == "/api/adventure/catalog":
                        result = adventure_view.collection(self.server.store, query.get("kind", [""])[0])
                    else:
                        result = adventure_view.gear_details(self.server.store, query.get("id", [""])[0])
                self._json({"result": result})
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
            return
        if parsed.path == "/api/export/ledger.csv":
            if not self._authorized():
                return
            with self.server.lock:
                if self.server.store.status != "ready":
                    self._json({"error": "资料库尚未创建。"}, 400)
                    return
                text = self.server.store.export_ledger()
            self._bytes(text.encode("utf-8"), "text/csv; charset=utf-8")
            return
        if parsed.path.startswith("/assets/mac/"):
            root = mac_asset_dir().resolve()
            name = parsed.path.removeprefix("/assets/mac/")
        else:
            root = asset_dir().resolve()
            name = parsed.path.removeprefix("/assets/").lstrip("/")
        asset = (root / name).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        if not self._valid_host():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            self.server.request_shutdown()
            self._json({"ok": True})
            return
        if not self._authorized():
            return
        try:
            if self.server.shutdown_requested.is_set():
                raise AppError("搞积蓄正在退出。", "shutting-down")
            payload = self._body()
            if parsed.path == "/api/desktop/open":
                target = payload.get("target")
                if not valid_target(target):
                    raise AppError("无法打开此搞积蓄页面。", "desktop-route")
                desktop = self.server.desktop
                if desktop:
                    desktop.open(target)
                else:
                    open_window(self.server.url + target)
                self._json({"ok": True})
                return
            if parsed.path == "/api/desktop/widgets":
                manager = self.server.desktop_widgets
                if manager is not None:
                    def open_route(route):
                        if self.server.desktop:
                            self.server.desktop.open("#" + route)
                        else:
                            open_window(self.server.url + "#" + route)
                    result = manager.request(payload, open_route)
                elif payload.get("command") == "status":
                    result = {"available": False, "windows": {}}
                else:
                    raise AppError("桌面小组件当前不可用。", "desktop-widget")
                self._json({"ok": True, "result": result})
                return
            if parsed.path == "/api/desktop/notification-test":
                tray = self.server.desktop_tray
                english = payload.get("language") == "en"
                now = time.monotonic()
                with self.server.lock:
                    if now - self.server.last_test_notice < 10:
                        raise AppError("Wait a moment before testing again." if english else "请稍候再测试通知。", "desktop-notice")
                    self.server.last_test_notice = now
                title, body = (
                    ("Gao Savings · Notification test", "Fixed expenses and due dates appear here.")
                    if english else ("搞积蓄 · 通知测试", "固定支出与到期事项提醒会显示在这里。")
                )
                if tray is None or not tray.test_notification(title, body):
                    raise AppError("Windows did not accept the notification." if english else "Windows 未接受通知。", "desktop-notice")
                self._json({"ok": True, "result": {"submitted": True}})
                return
            with self.server.lock:
                if self.server.shutdown_requested.is_set():
                    raise AppError("搞积蓄正在退出。", "shutting-down")
                if self.server.store.status == "ready":
                    self.server.store.notice = ""
                result = dispatch(self.server.store, parsed.path, payload)
                snapshot = self.server.store.snapshot()
                snapshot["monthlyIntegration"] = self.server.monthly_integration.state
                if parsed.path.startswith("/api/monthly/") or parsed.path == "/api/library/create":
                    self.server.monthly_integration.notify()
            self._json({"ok": True, "result": result, "state": snapshot})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
        except OSError:
            self._json({"ok": False, "error": "资料写入未能完成，恢复后将重新核对。", "code": "persistence"}, 500)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            self._json({"ok": False, "error": "请求无法读取。", "code": "invalid"}, 400)

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _authorized(self) -> bool:
        if self.headers.get("X-Gao-Token") == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _valid_host(self) -> bool:
        host, port = self.server.server_address[:2]
        if self.headers.get("Host") in {f"{host}:{port}", f"localhost:{port}"}:
            return True
        self._json({"error": "仅可从本机打开搞积蓄。"}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 8 * 1024 * 1024:
            raise AppError("上传超过 8 MiB。", "invalid")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            raise AppError("请求体须为 JSON 对象。", "invalid")
        return data

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(body, "application/json; charset=utf-8", status)

    def _bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(store: Store, path: str, payload: dict):
    if path == "/api/library/create":
        return store.create_library()
    if path == "/api/settings":
        return store.update_settings(payload)
    if path == "/api/settings/folder":
        store.require_ready()
        folders = {"library": store.directory, "widgets": store.directory / "IsolatedWidgetGroup"}
        directory = folders.get(payload.get("folder"))
        if os.name != "nt" or directory is None or not directory.is_dir():
            raise AppError("无法打开现用资料目录。", "invalid")
        try:
            os.startfile(directory.resolve())
        except OSError as exc:
            raise AppError("无法在文件资源管理器中打开资料目录。", "invalid") from exc
        return {"opened": True}
    if path == "/api/accounts/save":
        return _public_id(finance.save_account(store, payload))
    if path == "/api/accounts/delete":
        return finance.delete_account(store, payload["id"])
    if path == "/api/ledger/save":
        if "amountExpression" in payload:
            payload = {**payload, "amount": finance_views.evaluate_amount(payload["amountExpression"])}
        return _public_id(finance.save_entry(store, payload))
    if path == "/api/ledger/delete":
        finance.delete_entry(store, payload["id"])
        return {"deleted": True}
    if path == "/api/budgets/save":
        finance.save_budget(store, payload)
        return {"saved": True}
    if path == "/api/budgets/batch":
        finance.save_budgets(store, payload)
        return {"saved": True}
    if path == "/api/recurring/save":
        if "amountExpression" in payload:
            payload = {**payload, "amount": finance_views.evaluate_amount(payload["amountExpression"])}
        return finance.save_rule(store, payload)
    if path == "/api/recurring/delete":
        finance.delete_rule(store, payload["id"])
        return {"deleted": True}
    if path == "/api/recurring/toggle":
        return finance.toggle_rule(store, payload["id"])
    if path == "/api/goals/save":
        return _public_id(finance.save_goal(store, payload))
    if path == "/api/goals/status":
        return finance.set_goal_status(store, payload["id"], payload["status"])
    if path == "/api/goals/delete":
        finance.delete_goal(store, payload["id"])
        return {"deleted": True}
    if path == "/api/records/save":
        return _public_id(finance.save_record(store, payload))
    if path == "/api/records/delete":
        finance.delete_record(store, payload["id"])
        return {"deleted": True}
    if path == "/api/fixed-income/save":
        return finance.save_fixed_income(store, payload)
    if path == "/api/fixed-income/enable":
        return finance.set_fixed_income_enabled(store, payload["id"], bool(payload.get("enabled")))
    if path == "/api/fixed-income/confirm":
        return finance.confirm_fixed_income(store, payload)
    if path == "/api/monthly/create":
        return store.create_monthly()
    if path == "/api/monthly/subscription":
        store.require_ready()
        return monthly.save_subscription(store.directory, payload, store.now)
    if path == "/api/monthly/pay":
        return monthly_bridge.confirm(store, payload)
    if path == "/api/monthly/change":
        return monthly_bridge.change_item(store, payload)
    if path == "/api/monthly/event":
        store.require_ready()
        return monthly.save_event(store.directory, payload, store.now)
    if path == "/api/monthly/review":
        store.require_ready()
        return monthly.save_review(store.directory, payload, store.now)
    if path == "/api/monthly/preferences":
        store.require_ready()
        return monthly.update_preferences(store.directory, payload, store.now)
    if path == "/api/monthly/reconcile":
        return monthly_bridge.reconcile(store, payload)
    if path == "/api/adventure/tick":
        count = int(payload.get("count") or 1)
        if count < 1 or count > 30:
            raise AppError("一次最多结算 30 个回合。", "invalid")
        last = None
        for _ in range(count):
            last = adventure.battle_tick(store)
        return last
    if path == "/api/adventure/draw":
        return adventure.draw(store, int(payload.get("count") or 1), payload.get("pool") or "equipment")
    if path == "/api/adventure/exchange":
        return adventure.exchange_resource(store, payload.get("resource") or "tickets")
    if path == "/api/adventure/equip":
        adventure.equip(store, payload["id"])
        return {"equipped": True}
    if path == "/api/adventure/equip-best":
        return adventure.equip_best(store)
    if path == "/api/adventure/unequip":
        return adventure.unequip(store, payload["slot"])
    if path == "/api/adventure/enhance":
        return adventure.enhance(store, payload["id"])
    if path == "/api/adventure/sell":
        return adventure.sell_equipment(store, payload["id"], int(payload.get("count", 1)))
    if path == "/api/adventure/sell-group":
        return adventure.sell_equipment_group(store, int(payload["rarity"]) if "rarity" in payload else None)
    if path == "/api/adventure/technique":
        adventure.equip_technique(store, payload["id"])
        return {"equipped": True}
    if path == "/api/adventure/unequip-technique":
        return adventure.unequip_technique(store, payload["id"])
    if path == "/api/adventure/technique-best":
        return adventure.equip_best_techniques(store)
    if path == "/api/adventure/upgrade-technique":
        return adventure.upgrade_technique(store, payload["id"])
    if path == "/api/adventure/forget-techniques":
        return adventure.forget_techniques(store, int(payload["rarity"]))
    if path == "/api/adventure/hatch":
        return adventure.hatch_pet(store)
    if path == "/api/adventure/pet":
        adventure.equip_pet(store, payload["id"])
        return {"equipped": True}
    if path == "/api/adventure/unequip-pet":
        return adventure.unequip_pet(store, payload["id"])
    if path == "/api/adventure/pet-best":
        return adventure.equip_best_pets(store)
    if path == "/api/csv/import":
        return store.import_ledger(payload.get("text") or "")
    if path == "/api/csv/preview":
        return csvutil.preview_ledger(store, payload.get("text") or "")
    if path == "/api/csv/review/stage":
        return csv_review.stage(store, payload)
    if path == "/api/csv/review/apply":
        return csv_review.apply(store, payload)
    if path == "/api/csv/review/undo":
        return csv_review.undo(store, payload)
    raise AppError("没有这个操作。", "invalid")


def _public_id(row: dict) -> dict:
    return {"id": row.get("id")}


def _battle_loop(server: SavingsServer) -> None:
    while not server.shutdown_requested.is_set():
        if os.environ.get("GAOJIXU_NO_BATTLE") == "1":
            server.shutdown_requested.wait(1)
            continue
        server.shutdown_requested.wait(1)
        if server.shutdown_requested.is_set():
            return
        with server.lock:
            if server.store.status == "ready":
                try:
                    adventure.battle_tick(server.store)
                except AppError:
                    return


def serve(store: Store, port: int = 0, open_browser: bool = True, instance_key: str = "") -> SavingsServer:
    server = SavingsServer(store, port=port, instance_key=instance_key)
    server.monthly_integration.thread.start()
    thread = threading.Thread(target=server.serve_forever, name="gaojixu-http", daemon=True)
    thread.start()
    server.battle_thread = threading.Thread(target=_battle_loop, args=(server,), name="gaojixu-battle", daemon=True)
    server.battle_thread.start()
    if open_browser:
        import webbrowser
        webbrowser.open(server.url)
    return server
