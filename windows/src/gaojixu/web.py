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

from gaojixu import adventure, finance, monthly
from gaojixu.errors import AppError
from gaojixu.resources import asset_dir
from gaojixu.store import Store, post_monthly_to_ledger
from gaojixu.version import VERSION_LABEL


class SavingsServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, store: Store, host: str = "127.0.0.1", port: int = 0):
        self.store = store
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.shutdown_requested = threading.Event()
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"


class Handler(BaseHTTPRequestHandler):
    server: SavingsServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                self._json(self.server.store.snapshot())
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
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self._authorized():
            return
        try:
            payload = self._body()
            with self.server.lock:
                result = dispatch(self.server.store, parsed.path, payload)
            self._json({"ok": True, "result": result, "state": self.server.store.snapshot()})
        except AppError as exc:
            self._json({"ok": False, "error": exc.message, "code": exc.code}, 400)
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
    if path == "/api/accounts/save":
        return _public_id(finance.save_account(store, payload))
    if path == "/api/accounts/delete":
        return finance.delete_account(store, payload["id"])
    if path == "/api/ledger/save":
        return _public_id(finance.save_entry(store, payload))
    if path == "/api/ledger/delete":
        finance.delete_entry(store, payload["id"])
        return {"deleted": True}
    if path == "/api/budgets/save":
        finance.save_budget(store, payload)
        return {"saved": True}
    if path == "/api/recurring/save":
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
        return monthly.save_subscription(store.directory, payload, store.now)
    if path == "/api/monthly/pay":
        result = monthly.record_payment(store.directory, payload, store.now)
        ledger_id = None
        if payload.get("accountID") and not payload.get("skipped"):
            state = monthly._require(store.directory)
            subscription = next(row for row in state.get("subscriptions") or [] if row.get("id") == result["payment"]["subscriptionID"])
            ledger_id = post_monthly_to_ledger(store, result["payment"], subscription, payload["accountID"])
        result["ledgerID"] = ledger_id
        return result
    if path == "/api/monthly/benefit":
        return monthly.save_benefit(store.directory, payload, store.now)
    if path == "/api/monthly/claim":
        return monthly.claim_benefit(store.directory, payload["id"], store.now)
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
        return adventure.exchange_ticket(store)
    if path == "/api/adventure/equip":
        adventure.equip(store, payload["id"])
        return {"equipped": True}
    if path == "/api/adventure/equip-best":
        return adventure.equip_best(store)
    if path == "/api/adventure/enhance":
        return adventure.enhance(store, payload["id"])
    if path == "/api/adventure/technique":
        adventure.equip_technique(store, payload["id"])
        return {"equipped": True}
    if path == "/api/adventure/technique-best":
        return adventure.equip_best_techniques(store)
    if path == "/api/adventure/upgrade-technique":
        return adventure.upgrade_technique(store, payload["id"])
    if path == "/api/adventure/hatch":
        return adventure.hatch_pet(store)
    if path == "/api/adventure/pet":
        adventure.equip_pet(store, payload["id"])
        return {"equipped": True}
    if path == "/api/csv/import":
        return store.import_ledger(payload.get("text") or "")
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


def serve(store: Store, port: int = 0, open_browser: bool = True) -> SavingsServer:
    server = SavingsServer(store, port=port)
    thread = threading.Thread(target=server.serve_forever, name="gaojixu-http", daemon=True)
    thread.start()
    battle = threading.Thread(target=_battle_loop, args=(server,), name="gaojixu-battle", daemon=True)
    battle.start()
    if open_browser:
        import webbrowser
        webbrowser.open(server.url)
    return server
