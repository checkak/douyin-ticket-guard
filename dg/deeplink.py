"""深链构造：把「商品ID + 票档 + 人数」变成一句能直接落到订单页的 URL。

说明（Inferred）：视频里 1:18 起 App 后直接停在「确认订单」，说明深链已带
商品/票档/人数参数。抖音的 scheme 没有公开文档，所以这里给的是候选表 +
探测器：`dg probe` 会逐个拉起并记录哪个落点正确，绑定后写进 config.json。
"""
from __future__ import annotations

import urllib.parse as up

SHOW_H5 = "https://life.douyin.com/p/show/detail"
SKU_H5 = "https://life.douyin.com/p/show/sku"

SCHEMES = {
    "douyin": "snssdk1128",
    "douyin_lite": "douyinlite",
}


def _q(**kw) -> str:
    return up.urlencode({k: v for k, v in kw.items() if v not in (None, "")})


def show_h5(product_id: str, session: str = "", sku: str = "", count: int = 1) -> str:
    return f"{SHOW_H5}?{_q(product_id=product_id, session_time=session, sku_name=sku, buy_count=count)}"


def build(kind: str, product_id: str, *, session: str = "", sku: str = "",
          sku_id: str = "", count: int = 1, app: str = "douyin_lite") -> str:
    """kind: webview | show | universal | order"""
    scheme = SCHEMES.get(app, "snssdk1128")
    inner = show_h5(product_id, session, sku, count)
    if kind == "webview":
        return f"{scheme}://webview?url={up.quote(inner, safe='')}"
    if kind == "show":
        return f"{scheme}://life_show/detail?{_q(product_id=product_id, session_time=session, sku_id=sku_id, count=count)}"
    if kind == "universal":
        return inner
    if kind == "order":
        return f"https://life.douyin.com/p/order/detail?{_q(product_id=product_id, order_id='')}"
    raise ValueError(kind)


def candidates(product_id: str, *, session: str = "", sku: str = "", count: int = 1) -> list[tuple[str, str]]:
    """探测顺序：Universal Link 最稳（iOS 会自己做 App/浏览器 fallback），其次 webview。"""
    out = []
    for app in ("douyin_lite", "douyin"):
        for kind in ("universal", "webview", "show"):
            out.append((f"{app}/{kind}", build(kind, product_id, session=session, sku=sku,
                                               count=count, app=app)))
    return out
