import re, pathlib, requests

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Mobile/15E148 Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)")
JS = ("https://lf-local-life-tos.bytedcdn.com/obj/local-life-transaction/1325/gecko/resource/"
      "life_services_product_detail_fe/static/js/trade_detail.991bbada.js")

s = requests.Session()
s.headers.update({"User-Agent": UA, "Referer": "https://life.scsjsd.com/"})
r = s.get(JS, timeout=30)
print("bundle:", len(r.content), "bytes", r.status_code)
pathlib.Path("trade_detail.js").write_text(r.text, encoding="utf-8")

api = sorted(set(re.findall(r'"(/[a-z0-9_/\-]{6,60})"', r.text)))
print("\n候选接口路径:")
for a in api:
    if any(k in a for k in ("trade", "product", "sku", "poi", "life", "order", "show")):
        print("  ", a)

print("\n关键参数名出现次数:")
for k in ("product_id", "activity_id", "spu_id", "sku_id", "poi_id", "session_id",
          "sku_list", "stock", "ticket_type", "audience", "a_bogus", "msToken"):
    print(f"  {k:14s}", r.text.count(k))
