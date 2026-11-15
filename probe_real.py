"""拿这条真实链接的 id 去验证：库存接口裸调（无 Cookie）到底回什么。"""
import json
import requests

ACTIVITY_ID = "1881078666742800"
POI_ID = "7700588591658829887"
UA = ("com.ss.android.ugc.aweme.lite/3290 (iPhone; iOS 15.1; Scale/3.00) "
      "Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15")

BASE = "https://life5-normal-m-zb.amemv.com"
COMMON = {
    "in_sp_time": "0", "need_personal_recommend": "1", "version_code": "32.9.0",
    "js_sdk_version": "3.56.0.8", "tma_jssdk_version": "3.56.0.8", "app_name": "douyin_lite",
    "app_version": "32.9.0", "device_id": "378384735535206496", "channel": "App Store",
    "mcc_mnc": "46001", "aid": "2329", "minor_status": "0", "screen_width": "1242",
    "cdid": "A85A1108-A466-405C-B215-E65B7896B593", "os_api": "18", "ac": "4G",
    "os_version": "15.1", "package": "com.ss.android.ugc.aweme.lite",
}

TRIES = [
    ("get_show_sku_info", "/data/v1/life/general/facade/get_show_sku_info",
     {"product_id": ACTIVITY_ID}),
    ("get_show_sku_info(activity)", "/data/v1/life/general/facade/get_show_sku_info",
     {"activity_id": ACTIVITY_ID, "poi_id": POI_ID}),
    ("get_product_detail", "/data/v1/life/general/facade/get_product_detail",
     {"product_id": ACTIVITY_ID, "poi_id": POI_ID}),
    ("trade_detail", "/data/v1/life/general/facade/get_poi_product_detail",
     {"product_id": ACTIVITY_ID, "poi_id": POI_ID}),
]

s = requests.Session()
s.headers.update({"User-Agent": UA, "Referer": "https://life.douyin.com/",
                  "Accept": "application/json"})

for name, path, extra in TRIES:
    params = dict(COMMON)
    params.update(extra)
    try:
        r = s.get(BASE + path, params=params, timeout=15)
        body = r.text[:400].replace("\n", " ")
    except Exception as e:                                   # noqa: BLE001
        body = f"{type(e).__name__}: {e}"
    print(f"[{name}] {r.status_code if 'r' in dir() else 'ERR'}")
    print("   ", body)
    print()
