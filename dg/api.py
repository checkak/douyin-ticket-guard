"""抖音生活服务/演出 票档接口客户端。

来源：视频 0:26 抓到的真实请求
  GET https://life5-normal-m-zb.amemv.com/data/v1/life/general/facade/get_show_sku_info
      ?in_sp_time=0&need_personal_recommend=1&version_code=32.9.0&...
      Cookie: sessionid=...; sid_guard=...; d_ticket=...

响应 schema 未在视频里暴露，所以库存抽取用「容错遍历」实现：
  - 正常情况直接命中 stock/stock_num/remain 等键
  - schema 变了也能跑；绑定阶段用 `dump` 把真实 JSON 存下来再收紧
"""
from __future__ import annotations

import json
import random
import time
from dataclasses import dataclass, field
from typing import Any, Iterable

import requests

API_HOST = "https://life5-normal-m-zb.amemv.com"
SKU_PATH = "/data/v1/life/general/facade/get_show_sku_info"

# 直接照抄视频里的客户端参数，保持与 App 一致的风控画像
BASE_PARAMS = {
    "in_sp_time": "0",
    "need_personal_recommend": "1",
    "version_code": "32.9.0",
    "js_sdk_version": "3.56.0.8",
    "tma_jssdk_version": "3.56.0.8",
    "app_name": "douyin_lite",
    "app_version": "32.9.0",
    "channel": "App Store",
    "mcc_mnc": "46001",
    "aid": "2329",
    "minor_status": "0",
    "screen_width": "1242",
    "os_api": "18",
    "ac": "4G",
    "os_version": "15.1",
    "package": "com.ss.android.ugc.aweme.lite",
}

UA_IOS = ("com.ss.android.ugc.aweme.lite/3290 (iPhone; iOS 15.1; Scale/3.00) "
          "Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15")

STOCK_KEYS = ("stock", "stock_num", "remain_stock", "remain", "left_stock", "inventory",
              "stock_count", "surplus", "available_num", "remain_num")
PRICE_KEYS = ("price", "sale_price", "origin_price", "market_price", "discount_price")
NAME_KEYS = ("sku_name", "name", "title", "ticket_name", "sku_title", "seat_name")
ID_KEYS = ("sku_id", "id", "spu_id", "product_id")


@dataclass
class Sku:
    sku_id: str
    name: str
    price: float
    stock: int
    raw: dict = field(default_factory=dict, repr=False)

    @property
    def price_yuan(self) -> float:
        # 接口常用「分」计价（78000 = ¥780）
        return self.price / 100 if self.price >= 1000 else self.price

    def __str__(self) -> str:
        return f"{self.name} ¥{self.price_yuan:g} 剩余{self.stock}张"


@dataclass
class Snapshot:
    ts: float
    product_id: str
    skus: list[Sku]
    raw: dict

    def by_name(self, needle: str) -> Sku | None:
        needle = (needle or "").replace(" ", "")
        for s in self.skus:
            if needle and needle in s.name.replace(" ", ""):
                return s
        return None

    def by_price(self, yuan: float) -> Sku | None:
        for s in self.skus:
            if abs(s.price_yuan - yuan) < 0.5:
                return s
        return None


class TicketClient:
    def __init__(self, cookies: dict[str, str], headers: dict[str, str] | None = None,
                 timeout: float = 6.0, sign_hook=None, proxy: str | None = None):
        self.s = requests.Session()
        self.timeout = timeout
        self.sign_hook = sign_hook          # callable(session, url, params) -> None
        self.last_raw: dict | None = None
        self.cookies = dict(cookies)
        h = {
            "User-Agent": UA_IOS,
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://life.douyin.com/",
            "Accept-Language": "zh-CN,zh;q=0.9",
        }
        h.update({k: v for k, v in (headers or {}).items() if k.lower().startswith(("x-", "referer"))})
        self.s.headers.update(h)
        if proxy:
            self.s.proxies = {"http": proxy, "https": proxy}
        for k, v in self.cookies.items():
            self.s.cookies.set(k, v, domain=".amemv.com")

    # ---------------- 拉库存 ----------------
    def get_show_sku_info(self, product_id: str, extra: dict | None = None) -> Snapshot:
        params = dict(BASE_PARAMS)
        params["device_id"] = str(random.randint(10**17, 10**18))
        params["cdid"] = _uuid_like()
        # 商品ID 的键名不同版本有差异，一次带上常用的几个（多传不会导致失败）
        params["product_id"] = product_id
        params["show_id"] = product_id
        params["spu_id"] = product_id
        if extra:
            params.update(extra)

        url = API_HOST + SKU_PATH
        if self.sign_hook:
            self.sign_hook(self.s, url, params)

        r = self.s.get(url, params=params, timeout=self.timeout)
        r.raise_for_status()
        data = r.json()
        self.last_raw = data
        return Snapshot(ts=time.time(), product_id=product_id, skus=extract_skus(data), raw=data)


def _uuid_like() -> str:
    import uuid
    return str(uuid.uuid4()).upper()


def extract_skus(data: Any) -> list[Sku]:
    """容错遍历：任何包含「库存键 + 价格键」的 dict 都当成一个票档。"""
    out: list[Sku] = []

    def pick(d: dict, keys: Iterable[str]):
        for k in keys:
            if k in d and d[k] not in (None, ""):
                return d[k]
        return None

    def walk(node: Any):
        if isinstance(node, dict):
            stock = pick(node, STOCK_KEYS)
            price = pick(node, PRICE_KEYS)
            if stock is not None and price is not None:
                try:
                    name = pick(node, NAME_KEYS) or f"sku-{pick(node, ID_KEYS) or len(out)}"
                    out.append(Sku(
                        sku_id=str(pick(node, ID_KEYS) or ""),
                        name=str(name),
                        price=float(price),
                        stock=int(float(stock)),
                        raw=node,
                    ))
                except (TypeError, ValueError):
                    pass
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(data)
    # 同名同价去重（接口常把同一票档挂在 show/sku/stock 三处）
    seen, uniq = set(), []
    for s in out:
        key = (s.name, s.price_yuan)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(s)
    return uniq


def dump_schema(data: Any, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
