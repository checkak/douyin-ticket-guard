"""用真实浏览器接管 H5，直接截获商品详情响应（免签名）。

原理：页面自己会带着合法签名去请求 `/v2/poi/user/trade/product/info/`，
我们不伪造签名，只挂 CDP 把那条 response body 拿下来 —— sku_list + 库存全在里面。

  python browser_probe.py "https://v.douyin.com/nQc94SXlb_Q/" 
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse as up
import urllib.request
from pathlib import Path

from websockets.sync.client import connect

EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
]
PORT = 9333
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Mobile/15E148 Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)")
WANT = ("product/info", "trade/product", "get_show_sku_info", "product_detail")


def find_browser() -> str:
    for p in EDGE_CANDIDATES:
        if os.path.exists(p):
            return p
    raise SystemExit("没找到 Edge/Chrome")


def http_json(path: str, method: str = "GET"):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode("utf-8", "ignore"))


def wait_port(timeout: float = 20.0) -> None:
    end = time.time() + timeout
    while time.time() < end:
        try:
            http_json("/json/version")
            return
        except Exception:                                    # noqa: BLE001
            time.sleep(0.4)
    raise SystemExit("CDP 端口没起来")


class CDP:
    def __init__(self, ws_url: str):
        self.ws = connect(ws_url, max_size=None, open_timeout=20)
        self.id = 0
        self.events: list[dict] = []

    def call(self, method: str, params: dict | None = None, timeout: float = 20.0) -> dict:
        self.id += 1
        mid = self.id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        end = time.time() + timeout
        while time.time() < end:
            msg = json.loads(self.ws.recv(timeout=max(0.1, end - time.time())))
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
            if "method" in msg:
                self.events.append(msg)
        raise TimeoutError(method)

    def drain(self, seconds: float) -> list[dict]:
        end = time.time() + seconds
        while time.time() < end:
            try:
                msg = json.loads(self.ws.recv(timeout=max(0.05, end - time.time())))
            except TimeoutError:
                break
            except Exception:                                # noqa: BLE001
                break
            if "method" in msg:
                self.events.append(msg)
        return self.events


def run(url: str, wait_s: float = 18.0, out_dir: str = ".") -> int:
    exe = find_browser()
    profile = tempfile.mkdtemp(prefix="dg_cdp_")
    proc = subprocess.Popen(
        [exe, "--no-first-run", "--no-default-browser-check",
         f"--remote-debugging-port={PORT}", f"--user-data-dir={profile}",
         "--window-size=430,900", "--window-position=-32000,-32000", "--start-minimized",
         "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_port()
        tab = http_json("/json/new?" + up.quote(url, safe=""), method="PUT")
        cdp = CDP(tab["webSocketDebuggerUrl"])
        cdp.call("Network.enable")
        cdp.call("Page.enable")
        cdp.call("Network.setUserAgentOverride", {"userAgent": UA,
                                                  "acceptLanguage": "zh-CN,zh;q=0.9"})
        cdp.call("Page.navigate", {"url": url})
        cdp.drain(wait_s)

        # 把命中的响应体全部抓下来
        hits = []
        for ev in cdp.events:
            if ev.get("method") != "Network.responseReceived":
                continue
            p = ev["params"]
            u = p["response"]["url"]
            if any(w in u for w in WANT):
                rid = p["requestId"]
                try:
                    body = cdp.call("Network.getResponseBody", {"requestId": rid})["body"]
                except Exception:                            # noqa: BLE001
                    continue
                hits.append((u, body))

        print(f"命中的接口响应: {len(hits)} 条")
        saved = 0
        for u, body in hits:
            name = f"cap_{saved}.json"
            Path(out_dir, name).write_text(body, encoding="utf-8")
            print(f"  [{saved}] {u[:110]}")
            print(f"      {len(body)} bytes → {name}  头部: {body[:200]}")
            saved += 1
        if not hits:
            # 退而求其次：把渲染后的 DOM 文本打出来
            dom = cdp.call("Runtime.evaluate", {
                "expression": "document.body.innerText", "returnByValue": True})
            text = dom.get("result", {}).get("value", "")
            Path(out_dir, "dom.txt").write_text(text or "", encoding="utf-8")
            print("没截到 JSON，已保存 dom.txt（%d 字）" % len(text or ""))
            print((text or "")[:600])
    finally:
        proc.terminate()
    return 0


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "https://v.douyin.com/nQc94SXlb_Q/"
    raise SystemExit(run(target))
