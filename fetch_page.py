import re, pathlib, requests

URL = "https://v.douyin.com/nQc94SXlb_Q/"
UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Mobile/15E148 Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)")

s = requests.Session()
s.headers.update({"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
r = s.get(URL, timeout=20)
html = r.text
pathlib.Path("page.html").write_text(html, encoding="utf-8")
print("final:", r.url.split("?")[0])
print("len:", len(html), "status:", r.status_code)

for key in ("product_id", "spu_id", "sku_id", "activity_id", "poi_id", "show_id",
            "ticket_price", "price", "stock"):
    hits = sorted(set(re.findall(rf'{key}["\s:=]+"?(\d{{3,25}})', html)))[:6]
    if hits:
        print(f"{key:14s}", hits)

m = re.search(r"<title>(.*?)</title>", html, re.S)
print("title:", (m.group(1).strip() if m else "-")[:160])

# 找页面里的 JSON 数据岛
for pat in (r'window\.__INITIAL_STATE__\s*=\s*(\{.*?\});',
            r'window\.__DATA__\s*=\s*(\{.*?\})',
            r'<script id="RENDER_DATA"[^>]*>(.*?)</script>'):
    mm = re.search(pat, html, re.S)
    if mm:
        print("found data island:", pat[:40], "len", len(mm.group(1)))
        pathlib.Path("page_data.txt").write_text(mm.group(1), encoding="utf-8")
        break
