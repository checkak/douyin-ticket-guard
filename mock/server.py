"""离线自测用的假接口：本地复现「0 张 → 168 张」的库存跃迁。

  python mock/server.py              # 127.0.0.1:18080
  python -m dg dump 1877446712185876 --api-base http://127.0.0.1:18080
  python -m dg run --dry-run --seconds 12 --api-base http://127.0.0.1:18080

前 3 次请求库存为 0（模拟"一直没票"），第 4 次起 780 档放 168 张、680 档 94 张，
正好用来验证「状态跃迁触发 + 去抖」是否正确。
"""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HITS = {"n": 0}
LOCK = threading.Lock()

SKUS = [
    ("看台 480", 48000, None),
    ("看台 680", 68000, 94),
    ("看台 780", 78000, 168),
    ("内场 980", 98000, 0),
    ("内场 1080", 108000, 0),
]


def payload(product_id: str, n: int) -> dict:
    # 4 次无票 / 4 次放票 交替，方便观察「无票 → 有票」跃迁触发
    released = (n % 8) >= 4
    sku_list = []
    for i, (name, price, stock_when_released) in enumerate(SKUS):
        stock = stock_when_released if released else 0
        sku_list.append({
            "sku_id": f"{product_id}{i:02d}",
            "sku_name": name,
            "price": price,
            "stock_num": stock,
            "sale_status": 1 if stock else 0,
        })
    return {
        "status_code": 0,
        "status_msg": "success",
        "data": {
            "show_info": {
                "product_id": product_id,
                "show_name": "张栋梁\u201c在风暴中心午睡\u201d巡回演唱会\u2014佛山站",
                "session_time": "2026-11-28 19:30",
                "limit_per_user": 2,
            },
            "sku_list": sku_list,
            "server_time": 1763800000 + n,
        },
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):       # 安静一点
        pass

    def do_GET(self):                        # noqa: N802
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if u.path == "/__stats":
            body = json.dumps({"hits": HITS["n"]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if u.path == "/__reset":
            with LOCK:
                HITS["n"] = 0
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if u.path.startswith("/s/"):                       # 模拟 v.douyin.com 短链
            self.send_response(302)
            self.send_header("Location", "/p/show/detail?product_id=1877446712185876")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if u.path == "/p/show/detail":                     # 模拟分享落地页
            html = ('<html><script>window.__DATA__={"product_id":"1877446712185876",'
                    '"show_name":"张栋梁\\u201c在风暴中心午睡\\u201d巡回演唱会\\u2014佛山站"};'
                    'location.href="snssdk1128://life_show/detail?product_id=1877446712185876"</script></html>')
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if "get_show_sku_info" in u.path:
            with LOCK:
                HITS["n"] += 1
                n = HITS["n"]
            pid = (qs.get("product_id") or qs.get("show_id") or ["0"])[0]
            body = json.dumps(payload(pid, n), ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


def serve(host: str = "127.0.0.1", port: int = 18080) -> None:
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"mock api on http://{host}:{port}  (前3次无票，第4次起放票)", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    serve()
