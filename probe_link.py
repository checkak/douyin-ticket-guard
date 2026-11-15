"""对这条真实链接的团购商品详情接口做裸调验证。

链路来自 H5 bundle（trade_detail.991bbada.js）：
  base: location.origin + /aweme
  GET  /v2/poi/user/trade/product/info/    商品详情 + sku_list（含库存）
  POST /v2/poi/user/trade/product/preview/ 预下单（选票档/人数）
  GET  /v2/poi/user/trade/product/qualification  实名/限购资格
"""
import json
import urllib.parse as up

import requests

ACTIVITY_ID = "1881078666742800"
POI_ID = "7700588591658829887"
SHARE_ID = "0ab436a105e64dcea3b5954df35951f5"
LIFE_SHARE_EXT = ("HpeK5vXiL+E\\/dwajohEt7FOtA6U4HXr2s0Rb5iNRAFj64fLNs\\/7zyV\\/2CUfzKdS1BfyoqZKC5JJq"
                  "hrtiAsW3MrPTPZCo7Gq18N5DOdOk9yB0gIoS87KCOGpe5\\/Ug11z\\/RTj\\/eSwrMx3IvvzuTNubYXGLgGRC"
                  "sBh0M1r5CSbmTvo0bCf0ysRDv72JBAUX5mxUBX5RYTmCddLW93OhppL41S8+ejFaQI2f3iHJ2Scxe3sWAN9Y5E"
                  "HTVKA7kqE9E\\/sSOCErsz4LKEVfiSmZgvqkj0+Ij036vDp4ho8gDrPs\\/gxqKfwSE0cNdZTV90wlB74Dij4Cn2"
                  "M3mz+AQU71VsNGoeMO8wdWpJA6J6SQlRI84jb0sKzm+FfKYNKwg3Ov\\/Y3+\\")

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Mobile/15E148 Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)")

ORIGIN = "https://life.scsjsd.com"
INFO = ORIGIN + "/aweme/v2/poi/user/trade/product/info/"

s = requests.Session()
s.headers.update({
    "User-Agent": UA,
    "Referer": ("https://life.scsjsd.com/falcon/poi_mwa/trade_detail?app=aweme"
                "&activity_id=" + ACTIVITY_ID),
    "Accept": "application/json, text/plain, */*",
})

CASES = {
    "仅 activity_id": {"activity_id": ACTIVITY_ID},
    "activity_id + poi_id": {"activity_id": ACTIVITY_ID, "poi_id": POI_ID},
    "activity_id + sign_token(share_ext)": {"activity_id": ACTIVITY_ID, "sign_token": LIFE_SHARE_EXT},
    "全套(含 life_share_id / sale_channel)": {
        "activity_id": ACTIVITY_ID, "poi_id": POI_ID, "sign_token": LIFE_SHARE_EXT,
        "request_params": json.dumps({"life_share_id": SHARE_ID}, separators=(",", ":")),
        "sale_channel": "share.general_search.default", "app": "aweme",
        "enter_from": "link", "source": "groupbuy",
    },
}

for name, extra in CASES.items():
    q = up.urlencode(extra)
    try:
        r = s.get(INFO + "?" + q, timeout=15)
        text = r.text.strip()
        head = text[:360].replace("\n", " ") if text else "<空响应体>"
        size = len(r.content)
        code = r.status_code
    except Exception as e:                                   # noqa: BLE001
        code, head, size = "ERR", f"{type(e).__name__}: {e}", 0
    print(f"[{name}] http={code} bytes={size}")
    print("   ", head)
    print()
