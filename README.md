# douyin_ticket_guard — 抖音演出票档监控 / 抢票工具（复刻 `1509184056.mp4` 那套）

对标视频里那套 iOS 工具的全部可复刻能力：

| 视频里的按钮 | 本实现 | 位置 |
|---|---|---|
| 粘贴 cURL / HAR / 订单链接 | `python -m dg sniff` | `dg/parse.py` |
| 加载（商品ID → 票档+库存） | `python -m dg dump` | `dg/api.py` |
| 无票行 `+监控` / 有票行 `购票` | `python -m dg add` / `dg probe` | `dg/engine.py` |
| 监控中心：阈值 / 自动下单 / 任务延迟 / 全局监控 / 定时 / 实时日志 | `Monitor` 全部实现 | `dg/engine.py` |
| 加入监控 → 通知 / 通知+自动打开抖音 | `auto_open` + `notify.py` | `dg/notify.py` |
| Bark「时效性」推送 + 铃响 | `bark_full()` | `dg/notify.py` |
| 唤起抖音（深链） | `deeplink.build()` + `open_url()` | `dg/deeplink.py` |
| 画中画 / 订单解析按钮 | 见下文「画中画」「订单页补全」 | — |

---

## 0. 一分钟跑起来（离线自测，不需要真 Cookie）

```bash
cd douyin_ticket_guard
pip install requests

# 1) 起假接口（4 次无票 / 4 次放票 交替）
python mock/server.py                                    # 另开一个终端

# 2) 解析视频里那条 cURL（样例已放进 samples/）
python -m dg sniff samples/curl_sniff.txt --save cookies.json
#   [curl] cookies=9 auth=Y product_id=1877446712185876

# 3) 建任务（= 视频 0:44「加入监控」）
python -m dg add --product-id 1877446712185876 \
  --name '张栋梁"在风暴中心午睡"巡回演唱会—佛山站' --session '2026-11-28 19:30' \
  --sku '看台 780' --count 2 --threshold 1 --interval 0.5

# 4) 开跑（= 视频 1:17「监听并触发监控已启动」）
python -m dg run --dry-run --seconds 20 --api-base http://127.0.0.1:18080
```

**实测输出**（本机 python 3.12.7 / requests 2.33.1）：

```
[18:03:53] INFO ✅ 监听并触发监控已启动 张栋梁…佛山站 | 2026-11-28 19:30 | 看台 780 阈值=1 间隔=0.5s
[18:03:55] HIT 【11-28】张栋梁…佛山站 | 2026-11-28 19:30 | 看台 780｜看台 780 有票168张（阈值1）通知打开抖音
[18:04:00] HIT …（冷却期后二次跃迁再次触发）
[18:04:05] HIT …
[18:04:10] HIT …
```

把 `DG_REFIRE_COOLDOWN` 调回默认 20 秒，就只在「无票→有票」那一下响一次——与视频里 1:18 只推一条的行为一致。

---

## 1. 真实使用（绑定你自己的登录态）

```bash
# A. 手机上用 ProxyPin / Stream 抓一次抖音的「演出详情」请求
#    抓不到就随便点开一个演出页，筛 host=life5-normal-m-zb.amemv.com
#    导出 cURL 或 HAR，发到电脑存成 sn.bin

python -m dg sniff sn.bin --save cookies.json       # 提取 sessionid / sid_guard / d_ticket
python -m dg dump 1877446712185876                  # 先确认能不能拿到库存数字
python -m dg list
python -m dg run --bark <你的Bark Key>
```

`dump` 若返回 `解析到 0 个票档`，说明响应 schema 与默认键名不同：

```bash
python -m dg dump 1877446712185876 --out schema.json
# 打开 schema.json 看真实键名，改 api.py 里的 STOCK_KEYS / PRICE_KEYS / NAME_KEYS
```

若返回 `403 / 空 data / verify` 之类：

| 现象 | 原因 | 处理 |
|---|---|---|
| `status_code != 0`、`data` 为空 | 缺 `a_bogus`/`X-Argus`/`msToken` 签名参数 | 用 `sign_hook` 注入（见 §4） |
| 401 / 需要登录 | Cookie 过期或不完整 | 重新抓，确保含 `sessionid`+`sid_guard`+`d_ticket` |
| 429 / 频繁 | 轮询太快 | `--interval` 提到 3~5s，换出口 IP |
| 200 但库存恒为 0 | 抓的是别的商品/场次 | 核对 `product_id`（视频里 19 位数字） |

---

## 2. 架构

```
sn.bin(cURL/HAR) ──► parse.sniff() ──► cookies.json + headers.json
                                          │
product_id ──► api.TicketClient.get_show_sku_info() ──► Snapshot([Sku(name,price,stock)])
                                          │
                    engine.Monitor（每任务一线程）
                     ├ 阈值判定 + 状态跃迁去抖 + 冷却
                     ├ 全局监控 / 定时启动 / 任务错峰(task_delay)
                     └ 命中 ──► notify.bark_full()  （Bark 时效性 + 铃响，永远执行）
                              └─► deeplink.build() + notify.open_url()（可选，自动跳确认订单）
```

## 3. 字段对照（视频 UI ↔ 本实现）

| 视频 UI | 参数 | 默认 |
|---|---|---|
| 阈值 | `threshold` | 1 |
| 自动下单 | `auto_order` | False |
| 任务延迟(秒) | `task_delay`（任务间错峰） | 5.0 |
| 全局监控 | `global_watch`（整场所有票档都盯） | False |
| 定时 | `schedule_at`（`HH:MM`） | 空 |
| 购票人数 | `count` | 1 |
| 加入监控的两个选项 | `auto_open=True/False` | True（= 通知并自动打开抖音） |
| 轮询间隔 | `interval` | 1.0 |

## 4. 签名参数（要做「自动下单」必须先补这块）

`get_show_sku_info` 是 GET + Cookie，多数情况下裸调就能过；
但**下单链路**（预下单/确认/支付）一定带签名。留了钩子：

```python
# dg/api.py 已支持 sign_hook(session, url, params)
def sign(session, url, params):
    # 占位：按你抓到的请求补参数
    params["msToken"] = MS_TOKEN          # 从 HAR 的 X-Ms-Token / cookie 取
    params["a_bogus"] = bogus(url, params)  # 见下
    session.headers["X-Argus"] = ARGUS
    session.headers["X-Gorgon"] = GORGON
```

`bogus()` 的来源二选一：
1. **纯算法**：`a_bogus` 由 `UA + query + body + 时间戳` 经固定轮转/魔改 RC4 得出，社区有 Python 实现，按版本对；
2. **真机桥**：手机端 App 里 hook 出签名函数，用 `frida` 暴露一个本地端口，本工具 HTTP 调它拿签名（最稳，版本无关）。

下单链（占位，等抓包绑定）：

```python
# 1) 预下单
POST https://life5-normal-m-zb.amemv.com/data/v1/life/order/pre_create
     product_id, sku_id, count, session_time, audience_info[]
# 2) 确认订单（拿 order_id + 支付金额）
POST .../data/v1/life/order/confirm
# 3) 拉起支付
POST .../data/v1/life/order/pay   → 返回支付参数 → 交 App/收银台
```

实名/限购字段（`audience_info`：姓名 + 身份证号）在 **confirm 之前**就要提交，
服务端按身份证维度校验——这就是视频 1:28「该商品限购时，您已购买1张」的来源。

## 5. 深链绑定（视频 1:18 那一下）

```bash
python -m dg probe 1877446712185876 --session '2026-11-28 19:30' --sku '看台 780' --count 2
```

打印 6 条候选（`douyin_lite`/`douyin` × `universal`/`webview`/`show`）。逐个在手机上试，
哪个**直接落到「确认订单」页**，就把那个 `kind` 写进任务：

```bash
python -m dg add ... --link-kind universal      # 或 webview / show
```

安卓批量场景可走 adb：`notify.adb_open(serial, url)`。

## 6. 画中画 & 保活

轮询线程被系统冻结 = 漏票。视频里那个「画中画」按钮就是干这个的：

- iOS：H5 放 Safari 小窗 / 「快捷指令」后台+「低电量模式」关闭；
- Android：`adb shell am set-inactive <pkg> false`、关电池优化、前台服务；
- 本实现跑在电脑/服务器上最省事（不受手机休眠影响），只把「跳转」交给手机：
  Bark 推送里带 `url`，点通知即跳；或 `adb_open` 直接拉起。

## 7. 订单链接解析（视频 0:26「提取并补全」）

```bash
python -m dg sniff "https://life.douyin.com/p/order/detail?order_id=...  商品 1875023369174019 380元 2026-11-21 19:30"
# → product_id / session / price 一次抽出，再批量 combos 成订单页链接
```

## 8. 这套东西的天花板（视频 1:28 已经演给你看）

- **抢不到"资格"**：实名限购（`限购 6 张/人`、`您已购买1张`）在服务端按身份证校验，
  客户端做什么都没用；`--count` 只是凑单人数。
- **抢得到"票"**：库存接口若裸调可用，监控/推送/跳转这一整条链是纯工程问题，本仓库已实现。
- **风控面**：`device_id/cdid` 每请求随机、间隔抖动、同 IP 高频会进风控；生产用建议
  出口 IP 池 + 多账号 Cookie 池 + 每账号低频（视频里 5.0s 的「任务延迟」就是干这个的）。

## 9. 文件

```
douyin_ticket_guard/
├─ ANALYSIS-1509184056.md      # 视频逐帧分析（97 帧全覆盖）+ 逻辑还原
├─ FINDINGS-xuezhijian-wuxi.md # 真实链接（薛之谦无锡站）实测：接口链 + 裸调反证
├─ IPA-README.md               # 打包成 ipa / PWA 的完整步骤与限制
├─ README.md                   # 本文件
├─ dg/
│  ├─ parse.py                 # cURL / HAR / 订单链接 / 分享短链 → cookies + product_id
│  ├─ api.py                   # get_show_sku_info 客户端 + 容错库存抽取
│  ├─ engine.py                # 多任务监控 / 阈值 / 去抖 / 全局 / 定时 / 日志
│  ├─ notify.py                # Bark + 铃响 + 深链拉起（Win/mac/Linux/adb）
│  ├─ deeplink.py              # 深链构造 + 候选探测
│  └─ cli.py                   # 命令行入口
├─ ios/                        # SwiftUI 工程（XcodeGen）+ build_ipa.sh
│  └─ DouyinTicketGuard/       # App.swift / ApiClient / ImportParser / Store / Notifier / DeepLink / Views
├─ pwa/                         # 纯前端版：装到主屏幕即可用（无需 Mac）
├─ .github/workflows/ios-ipa.yml# GitHub macOS runner 自动出 ipa
├─ tools/                       # PWA 逻辑单测（17 项）+ HTML 接线检查
├─ mock/server.py              # 离线假接口（库存跃迁，自测用）
├─ samples/curl_sniff.txt      # 视频 0:26 那条 cURL 的重建样例
├─ tasks.json                  # 任务表（add/list/rm 自动维护）
└─ logs/monitor.log            # 实时日志（对应视频「实时日志」面板）
```

## 10. 依赖

`requests>=2.28`；可选 `winsound`(Win) / `afplay`(mac) / `adb`(安卓)。
Python 3.10+（用了 `X | None` 与 `dict[str,str]`）。
