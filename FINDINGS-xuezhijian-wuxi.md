# 实测记录：`https://v.douyin.com/nQc94SXlb_Q/`（薛之谦"万兽之王"无锡站 11-27）

> 执行时间 2026-11-15 18:1x，工具 `douyin_ticket_guard`
> 结论先行：**链接能拆到底，但这条链接本身不足以拉库存**——缺的是 web 端签名凭据，不是解析能力。

---

## 1. 短链展开（实测，Observed）

```
302 https://v.douyin.com/nQc94SXlb_Q/
200 https://life.scsjsd.com/falcon/poi_mwa/trade_detail?app=aweme&sale_channel=share.general_search.default
    &source=groupbuy&activity_id=1881078666742800&poi_id=7700588591658829887
    &request_params={"life_share_id":"0ab436a105e64dcea3b5954df35951f5"}
    &common_extra={"life_extra_info":"{\"life_share_ext\":\"HpeK5vXiL+E...Y3+\"}"}
```

| 字段 | 值 |
|---|---|
| activity_id（= productId） | `1881078666742800` |
| poi_id | `7700588591658829887` |
| life_share_id | `0ab436a105e64dcea3b5954df35951f5` |
| life_share_ext | 加密串（约 500 字符，内含 sign_token 一类凭据） |
| 落地页类型 | 团购商品详情（`trade_detail`），不是「演出票务」独立页 |

**关键实证**：H5 bundle 里 `productId: e.activity_id`（见 `trade_detail.js` 偏移 44997 附近），
所以这类链接的"商品ID"就是 activity_id，我的解析器取的没错。

## 2. 接口链（从 `trade_detail.991bbada.js` 挖出，Observed）

base = `location.origin + /aweme`（即 `https://life.scsjsd.com/aweme`）

| 端点 | 用途 |
|---|---|
| `GET /v2/poi/user/trade/product/info/` | 商品详情 + `sku_list`（含库存） |
| `POST /v2/poi/user/trade/product/preview/` | 预下单（票档/人数/选项） |
| `POST /v2/poi/user/trade/product/decision/update/` | 改选项（换票档、改人数） |
| `GET /v2/poi/user/trade/product/qualification` | **实名/限购资格校验** |
| `GET /data/v1/life/trip/refresh_product` | 刷新（带 `sign_token`） |
| 兜底 | `/v1/dito/disaster/product_goods_detail/`（主接口 503/429/555 时降级） |

## 3. 裸调结果（Observed，反面证据）

对 `product/info/` 打了 4 组参数，全部 **HTTP 200 + 响应体 0 字节**：

| 参数组合 | 结果 |
|---|---|
| 仅 `activity_id` | 200, 0 bytes |
| `activity_id` + `poi_id` | 200, 0 bytes |
| `activity_id` + `sign_token`(share_ext) | 200, 0 bytes |
| 全套（含 `life_share_id` / `sale_channel` / `app`） | 200, 0 bytes |

同样，视频里那个 `get_show_sku_info`（`life5-normal-m-zb.amemv.com`）裸调也是 200/0 字节。

**原因**：页面加载了 `sdk-glue.js`（`lf-c-flwb.bytetos.com/obj/rc-client-security/web/glue/1.0.0.56/`），
由它在请求上挂 `msToken` / csrf / `a_bogus` 一类参数。缺这些 → 服务端直接返回空体，不报错。

## 4. 浏览器接管方案（尝试过，本机受限）

`browser_probe.py` 已写好：起 Edge `--remote-debugging-port` → CDP 挂 `Network.responseReceived`
→ 直接 `getResponseBody` 拿那条已签名的 JSON（**完全不伪造签名**）。

本机实测：PowerShell 启动 Edge 时 CDP 正常应答（`Edg/157.0.4341.46`），
但从 Python `subprocess.Popen` 拉起时浏览器进程直接退出（`edge procs: 0`，端口拒连），
`--headless` 同样起不来 → 该路径在这台机器上不可用。换到有桌面会话的机器、或装 playwright 即可跑通。

## 5. 因此要真正跑起来，二选一

**A. 你给一条 cURL（30 秒见效）**
手机打开这条链接 → ProxyPin 抓 `trade/product/info` 那条 → 导出 cURL → `dg sniff` → 任务启用。

**B. 浏览器接管（换机器 / 装 playwright）**
`python browser_probe.py <链接>` 直接把接口 JSON 落到本地，再喂给 `api.extract_skus()`。

## 6. 该演唱会的已知信息（链接内）

- 演出：薛之谦"万兽之王"巡回演唱会 — 无锡站
- 场次：2026-11-27
- 票档/价格/库存：**未知**（藏在 `product/info` 的 `sku_list` 里，需要上面 A/B 之一才能读到）
- 该商品为「团购」形态（`source=groupbuy`），若为实名票，`qualification` 接口会做身份证维度的限购校验

任务已入库：`id=fdba969e`，`enabled=false`（等凭据）。
