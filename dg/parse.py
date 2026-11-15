"""cURL / HAR / 订单链接解析器。

目标：把 ProxyPin / Charles / 浏览器 DevTools 抓到的任意形态文本，压成
  - cookies: {name: value}
  - headers: {Name: value}（保留 UA / Referer / X-* 等）
  - product_id / session_time / price（订单页链接里带的信息）
一条 cURL 就够跑起来——视频里 0:26 那一页干的就是这件事。
"""
from __future__ import annotations

import json
import re
import shlex
import urllib.parse as up
from dataclasses import dataclass, field

# 抖音 H5 真正决定登录态的字段，缺 sid_guard/sessionid 基本等于未登录
AUTH_COOKIE_KEYS = (
    "sessionid", "sessionid_ss", "sid_guard", "sid_tt", "uid_tt", "uid_tt_ss",
    "d_ticket", "passport_csrf_token", "passport_csrf_token_default",
    "passport_mfa_token", "ttwid", "odin_tt", "store-region", "store-region-src",
)

COOKIE_RE = re.compile(r"(?P<k>[A-Za-z0-9_\-\.]+)=(?P<v>[^;,\s\"']*)")
PRODUCT_ID_RE = re.compile(r"\b(1\d{15,18})\b")            # 15~19 位商品ID（实测为 16 位）
DATE_RE = re.compile(r"\b(20\d{2}-\d{2}-\d{2})\b")
TIME_RE = re.compile(r"\b([01]\d|2[0-3]):[0-5]\d\b")
PRICE_RE = re.compile(r"(?:¥|￥)?\s*(\d{2,5}(?:\.\d{1,2})?)\s*元")


@dataclass
class Sniffed:
    source: str = ""                    # curl | har | link
    url: str = ""
    cookies: dict[str, str] = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)
    product_id: str = ""
    session: str = ""                   # 2026-11-21 19:30
    price: float = 0.0
    notes: list[str] = field(default_factory=list)

    @property
    def has_auth(self) -> bool:
        return bool({"sessionid", "sessionid_ss", "sid_guard"} & set(self.cookies))

    def cookie_header(self) -> str:
        return "; ".join(f"{k}={v}" for k, v in self.cookies.items())

    def summary(self) -> str:
        return (f"[{self.source}] cookies={len(self.cookies)} auth={'Y' if self.has_auth else 'N'} "
                f"product_id={self.product_id or '-'} session={self.session or '-'} "
                f"price={self.price or '-'}")


def _parse_cookie_string(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in COOKIE_RE.finditer(raw.replace("\\n", " ")):
        k, v = m.group("k"), m.group("v")
        if not v or v.lower() in ("path", "domain", "expires", "max-age", "samesite"):
            continue
        out[k] = v
    return out


def parse_curl(text: str) -> Sniffed:
    """解析单行/多行 cURL（-H / -b / -X / --data-raw / URL）。"""
    s = sniff = Sniffed(source="curl")
    # 去掉 Windows/终端粘贴产生的续行符
    cleaned = text.replace("\\\r\n", " ").replace("\\\n", " ").replace("^\n", " ")
    try:
        tokens = shlex.split(cleaned, posix=True)
    except ValueError:
        tokens = cleaned.split()

    url = ""
    for i, tok in enumerate(tokens):
        low = tok.lower()
        if low in ("-h", "--header") and i + 1 < len(tokens):
            h = tokens[i + 1]
            if ":" in h:
                k, v = h.split(":", 1)
                k, v = k.strip(), v.strip()
                if k.lower() == "cookie":
                    s.cookies.update(_parse_cookie_string(v))
                else:
                    s.headers[k] = v
        elif low in ("-b", "--cookie") and i + 1 < len(tokens):
            s.cookies.update(_parse_cookie_string(tokens[i + 1]))
        elif low.startswith("http://") or low.startswith("https://"):
            url = tok
    s.url = url or next((t for t in tokens if t.startswith("http")), "")
    if s.url:
        q = up.urlparse(s.url).query
        qs = up.parse_qs(q)
        for key in ("product_id", "show_id", "spu_id", "id"):
            if key in qs and not s.product_id:
                s.product_id = qs[key][0]
    _fill_from_free_text(s, text)
    return s


def parse_har(text: str) -> Sniffed:
    """解析 HAR：优先挑 get_show_sku_info / 带 product_id 的条目。"""
    data = json.loads(text)
    entries = (data.get("log") or {}).get("entries") or []
    best = None
    for e in entries:
        req = e.get("request") or {}
        url = req.get("url") or ""
        score = 0
        if "get_show_sku_info" in url:
            score += 100
        if "product_id" in url or "show" in url:
            score += 10
        if any(h.get("name", "").lower() == "cookie" for h in req.get("headers") or []):
            score += 5
        if best is None or score > best[0]:
            best = (score, req)

    s = Sniffed(source="har")
    if not best:
        s.notes.append("HAR 里没找到可用请求")
        return s
    req = best[1]
    s.url = req.get("url", "")
    for h in req.get("headers") or []:
        k = h.get("name", "")
        v = h.get("value", "")
        if k.lower() == "cookie":
            s.cookies.update(_parse_cookie_string(v))
        elif k:
            s.headers[k] = v
    if s.headers.get(":path"):
        s.url = s.url or s.headers.get(":path", "")
    _fill_from_free_text(s, s.url)
    s.notes.append(f"entries={len(entries)}, 选中 score={best[0]}")
    return s


def parse_order_link(text: str) -> Sniffed:
    """订单链接/订单分享文本 → 商品ID + 场次 + 价格（视频 0:26「提取并补全」）。"""
    s = Sniffed(source="link")
    m = re.search(r"https?://[^\s\"'<>]+", text)
    s.url = m.group(0) if m else ""
    _fill_from_free_text(s, text)
    if not s.product_id:
        s.notes.append("未识别到 19 位商品ID")
    return s


def _fill_from_free_text(s: Sniffed, text: str) -> None:
    if not s.product_id:
        m = PRODUCT_ID_RE.search(text)
        if m:
            s.product_id = m.group(1)
    date = DATE_RE.search(text)
    tm = TIME_RE.search(text)
    if date:
        s.session = date.group(1) + (f" {tm.group(0)}" if tm else "")
    if not s.price:
        m = PRICE_RE.search(text)
        if m:
            s.price = float(m.group(1))
    if not s.cookies:
        # 裸 Cookie 串（没 cURL 外壳）
        found = {k: v for k, v in _parse_cookie_string(text).items() if k in AUTH_COOKIE_KEYS}
        if len(found) >= 2:
            s.cookies.update(found)


def sniff(text: str) -> Sniffed:
    """自动识别形态：HAR(JSON) / cURL / 订单链接 / 裸 Cookie。"""
    t = text.strip().lstrip("\ufeff")
    head = t[:5000]
    if t.startswith("{") and ('"log"' in head or '"entries"' in head):
        return parse_har(t)
    if "curl" in t[:400].lower():
        return parse_curl(t)
    if t.startswith("http") or "http" in t[:200]:
        return parse_order_link(t)
    s = Sniffed(source="cookie")
    s.cookies.update(_parse_cookie_string(t))
    _fill_from_free_text(s, t)
    return s


# ------------------------------------------------------------------ 短链展开
UA_MOBILE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) "
             "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
             "Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)")

ID_IN_URL_RE = re.compile(r"(product_id|show_id|spu_id|activity_id|id)=(\d{15,19})")
ID_IN_BODY_RE = re.compile(r"\b(1\d{15,18})\b")


def resolve_short_link(url: str, max_hops: int = 8, timeout: float = 6.0,
                       proxy: str | None = None, cookies: dict | None = None) -> tuple[str, list[str]]:
    """抖音分享出来的 `https://v.douyin.com/xxxx/` 是短链，要多跳几层才露出真实页。

    返回 (最终URL, 跳转轨迹)。过程中顺手从 body/JS 里捞 product_id。
    """
    import requests
    from urllib.parse import urljoin

    s = requests.Session()
    s.headers.update({"User-Agent": UA_MOBILE, "Accept-Language": "zh-CN,zh;q=0.9"})
    if proxy:
        s.proxies = {"http": proxy, "https": proxy}
    for k, v in (cookies or {}).items():
        s.cookies.set(k, v, domain=".douyin.com")

    final, hops = url, []
    for _ in range(max_hops):
        try:
            r = s.get(final, allow_redirects=False, timeout=timeout)
        except Exception as e:                                # noqa: BLE001
            hops.append(f"{final} → {type(e).__name__}: {e}")
            break
        loc = r.headers.get("Location") or r.headers.get("location")
        hops.append(f"{r.status_code} {final}")
        if loc:
            final = urljoin(final, loc)
            if final.startswith("snssdk1128://") or final.startswith("douyinlite://"):
                hops.append(f"→ App scheme: {final}")
                break
            continue
        # 没有跳转：从 HTML/JS 里找 scheme 或 product_id
        body = r.text or ""
        m = re.search(r"(?:snssdk1128|douyinlite)://[^\"'\s<>]+", body)
        if m:
            hops.append(f"→ 内嵌 scheme: {m.group(0)[:120]}")
        pid = ID_IN_URL_RE.search(final) or ID_IN_URL_RE.search(body) or ID_IN_BODY_RE.search(body)
        if pid:
            key, val = (pid.group(1), pid.group(2)) if pid.re is ID_IN_URL_RE else ("id", pid.group(1))
            hops.append(f"→ {key}: {val}")
        break
    return final, hops
