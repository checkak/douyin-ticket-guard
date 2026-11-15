"""极简 CDP 客户端：接管已在调试端口上的 Chrome，执行 JS / 取 Cookie / 打开页面。

用法（其它脚本 import）：
    from cdp import CDP
    c = CDP(9333)
    c.goto("https://github.com")
    print(c.js("document.title"))

命令行自测：
    python tools/cdp.py eval "document.title"
    python tools/cdp.py goto https://github.com
"""
from __future__ import annotations

import json
import sys
import time
import urllib.parse as up
import urllib.request

from websockets.sync.client import connect


class CDP:
    def __init__(self, port: int = 9333, url: str | None = None):
        self.port = port
        self.ws = None
        self.id = 0
        if url:
            self.tab = self._new_tab(url)
        else:
            tabs = [t for t in self._json("/json/list") if t.get("type") == "page"]
            self.tab = tabs[0] if tabs else self._new_tab("about:blank")
        self._connect()

    # ---------- HTTP 端点 ----------
    def _json(self, path: str):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as r:
            return json.loads(r.read().decode("utf-8", "ignore"))

    def _new_tab(self, url: str) -> dict:
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/json/new?{up.quote(url, safe='')}", method="PUT")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read().decode("utf-8", "ignore"))

    def _connect(self) -> None:
        self.ws = connect(self.tab["webSocketDebuggerUrl"], max_size=None, open_timeout=20)
        self.call("Page.enable")
        self.call("Runtime.enable")

    # ---------- 调用 ----------
    def call(self, method: str, params: dict | None = None, timeout: float = 30.0) -> dict:
        self.id += 1
        mid = self.id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            try:
                msg = json.loads(self.ws.recv(timeout=max(0.1, end - time.time())))
            except TimeoutError:
                break
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
        raise TimeoutError(method)

    def js(self, expression: str, await_promise: bool = True, timeout: float = 40.0):
        res = self.call("Runtime.evaluate", {
            "expression": expression,
            "returnByValue": True,
            "awaitPromise": await_promise,
            "userGesture": True,
        }, timeout=timeout)
        if res.get("exceptionDetails"):
            raise RuntimeError(json.dumps(res["exceptionDetails"], ensure_ascii=False)[:400])
        return res.get("result", {}).get("value")

    def goto(self, url: str, wait: float = 3.0) -> None:
        self.call("Page.navigate", {"url": url})
        time.sleep(wait)

    def cookies(self, urls: list[str] | None = None) -> list[dict]:
        res = self.call("Network.getCookies", {"urls": urls or ["https://github.com"]})
        return res.get("cookies", [])

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:                                     # noqa: BLE001
            pass


def _main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "eval"
    c = CDP(9333)
    try:
        if cmd == "eval":
            print(json.dumps(c.js(argv[2]), ensure_ascii=False, indent=2))
        elif cmd == "goto":
            c.goto(argv[2], wait=float(argv[3]) if len(argv) > 3 else 4.0)
            print("title:", c.js("document.title"))
        elif cmd == "cookies":
            print(json.dumps([x["name"] for x in c.cookies()], ensure_ascii=False))
        else:
            print("unknown cmd")
            return 2
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
