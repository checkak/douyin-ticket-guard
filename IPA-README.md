# 打包成 IPA

## 先说结论

**这台 Windows 机器生成不了 .ipa**——`.ipa` 里的可执行文件必须由 Xcode 的 `iphoneos` SDK 编译，
Windows 上没有 `xcodebuild`/`codesign`。所以给了三条路，按"今天能不能用上"排序：

| 路线 | 需要什么 | 产出 | 时间 |
|---|---|---|---|
| **A. GitHub Actions**（推荐） | 一个 GitHub 仓库 | 真 `.ipa`（未签名，Artifacts 下载） | ~10 分钟 |
| **B. 本地 Mac** | 一台装了 Xcode 的 Mac | 真 `.ipa`（可签名） | ~5 分钟 |
| **C. PWA** | 一台能开网页的服务器（或局域网） | 加到主屏幕的独立 App，**今天就能用** | ~2 分钟 |

`.ipa` 出来之后，Windows 端用 **Sideloadly / AltStore** 重签安装（免费 Apple ID，7 天有效）。

---

## 路线 A：GitHub Actions 出 ipa（不需要 Mac）

```bash
cd douyin_ticket_guard
git init && git add . && git commit -m "ios app"
# 推到 GitHub（新建空仓库后）
git remote add origin https://github.com/<你的账号>/<仓库>.git
git push -u origin main
```

推上去之后：

1. 打开仓库 → **Actions** → 左侧 `Build unsigned IPA` → **Run workflow**
2. 等 ~8 分钟（`macos-14` runner 自带 Xcode 16）
3. 跑完在本次 run 页面底部 **Artifacts** 下载 `DouyinTicketGuard-ipa` → 里面是 `DouyinTicketGuard-unsigned.ipa`

流水线文件：`.github/workflows/ios-ipa.yml`，核心就三行：

```bash
xcodegen generate
xcodebuild -project DouyinTicketGuard.xcodeproj -scheme DouyinTicketGuard \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
zip -qry DouyinTicketGuard-unsigned.ipa Payload   # Payload/ 里放 .app
```

## 路线 B：本地 Mac 出 ipa

```bash
brew install xcodegen
cd ios
./build_ipa.sh              # 未签名 → DouyinTicketGuard-unsigned.ipa
TEAM_ID=ABCDE12345 ./build_ipa.sh signed   # 有开发者证书时直接签好
```

## 装到 iPhone

| 工具 | 平台 | 说明 |
|---|---|---|
| **Sideloadly** | Win/Mac | 拖入 ipa + Apple ID → 自动重签安装；免费证书 7 天，到期重装 |
| **AltStore / SideStore** | Win/Mac | 同上，支持自动续签（需常开电脑或 SideStore 曲线） |
| **TrollStore** | iOS 14–16.6.1（部分） | 免签直装，永久有效（看设备/系统） |
| **Xcode** | Mac | `Window > Devices` 直接拖 .app 进手机 |

装完还要：**设置 → 通用 → VPN与设备管理 → 信任你的开发者证书**，
然后 **设置 → 隐私与安全性 → 开发者模式 → 打开**（iOS 16+）。

Bundle ID 冲突（`com.local.dtguard` 被别人占了）就在 `ios/project.yml` 里改
`PRODUCT_BUNDLE_IDENTIFIER`，重新跑流水线。

---

## 路线 C：PWA（今天就能用，不用等构建）

`pwa/` 是一个纯前端版本，功能与 App 一致（解析 cURL、轮询、阈值、通知、跳转）。

### 1. 起服务（任选）

```bash
# 本机 + 局域网访问（手机连同一个 WiFi）
cd douyin_ticket_guard/pwa
python -m http.server 8080
# 手机 Safari 打开 http://<电脑IP>:8080
```

要外网访问就丢到任意静态托管（GitHub Pages / Vercel / Cloudflare Pages），
注意 **必须是 HTTPS**，否则 service worker 和通知都不工作。

### 2. 解决 CORS（关键）

浏览器直连 `life5-normal-m-zb.amemv.com` 会被 CORS 拦。挂一个 Cloudflare Worker：

```js
// Cloudflare Worker：/proxy?url=<encoded target>
export default {
  async fetch(req) {
    const u = new URL(req.url);
    const target = u.searchParams.get('url');
    if (!target) return new Response('missing url', { status: 400 });
    const r = await fetch(target, {
      headers: {
        'User-Agent': 'com.ss.android.ugc.aweme.lite/3290 (iPhone; iOS 15.1; Scale/3.00)',
        'Referer': 'https://life.douyin.com/',
        'Cookie': req.headers.get('x-dtg-cookie') || '',   // 页面把 Cookie 放这个头里带过来
      },
    });
    return new Response(r.body, {
      status: r.status,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'x-dtg-cookie',
        'Content-Type': 'application/json; charset=utf-8',
      },
    });
  },
};
```

部署后把 `https://xxx.workers.dev/proxy` 填进 PWA 的「代理」输入框。

### 3. 安装到主屏幕

Safari 打开页面 → 分享 → **添加到主屏幕** → 从主屏幕启动（全屏、无地址栏）。
iOS 16.4+ 支持下 Web Push，但本 PWA 用的是：
- 页面在前台时：`Notification` + Bark 双通道；
- 页面在后台/锁屏：只能靠 **Bark 推送**（所以 Bark Key 一定要填）。

---

## 工程结构

```
ios/
├─ project.yml                      # XcodeGen 工程描述（bundle id / 权限 / 白名单）
├─ build_ipa.sh                     # macOS 一键出 ipa（未签名/签名两种模式）
└─ DouyinTicketGuard/
   ├─ App.swift                     # 入口 + TabView（监控 / 导入 / 设置）
   ├─ Models.swift                  # Sku / WatchTask / LogLine / HitEvent
   ├─ ApiClient.swift               # get_show_sku_info + 容错库存抽取
   ├─ ImportParser.swift            # cURL / HAR / 订单链接 → cookies + product_id
   ├─ Store.swift                   # 监控引擎：轮询/阈值/跃迁去抖/后台刷新/持久化
   ├─ Notifier.swift                # 本地通知 + Bark + 铃声
   ├─ DeepLink.swift                # 深链构造 + 候选探测 + 拉起抖音
   └─ Views/
      ├─ MonitorView.swift          # 监控中心 + 任务编辑
      └─ ImportView.swift           # 订单链接解析 + 设置
pwa/
├─ index.html / app.js / sw.js / manifest.webmanifest
tools/
├─ test_pwa_logic.js                # Node 侧跑核心逻辑（17 项断言，已全通过）
└─ check_pwa.js                     # HTML/JS 接线检查
```

## 在 iOS 上必须知道的四件事（都已在代码里处理/标注）

1. **后台不能持续轮询**。iOS 只给 `BGAppRefreshTask`，粒度 ≥15 分钟且不保证执行。
   `Store.engineEnterBackground()` 会停掉高频循环、注册后台刷新、并依赖 Bark 兜底。
   真要抢票：保持 App 前台（引导式访问 / 画中画），或把轮询放服务器只让手机收推送。
2. **深链白名单**。`LSApplicationQueriesSchemes` 里已加 `snssdk1128` / `douyinlite` / `douyin`，
   否则 `canOpenURL` 直接 false。
3. **通知权限**。首次启动会申请；「时效性」需要 `interruptionLevel = .timeSensitive`（已用）。
   免打扰下能否响，取决于用户是否给到该 App 的时效性通知权限。
4. **最后一步支付必须人工**。App 只能把你送到确认订单页；`立即支付` 需要指纹/面容/免密。

## 已验证 / 未验证（诚实清单）

| 项 | 状态 |
|---|---|
| 解析 cURL / HAR / 分享链接 → cookies + 商品ID | **已验证**（PWA 版 Node 单测 17/17；Python 版实测） |
| 容错库存抽取（stock/price 键名多版本） | **已验证**（模拟响应 + mock server） |
| 阈值 + 跃迁去抖 + 冷却 | **已验证**（Python 实测日志、PWA Node 断言） |
| 深链构造 | **已验证**（URL 结构断言）；落到确认订单页需真机探测 `dg probe` |
| Swift 代码能否编译 | **未验证**（本机无 Xcode；语法/类型经人工核对，CI 上首次构建会暴露问题） |
| 后台刷新实际能不能及时抢到 | **未验证**（受 iOS 调度影响，设计上不依赖它） |
| 真实接口能否返回库存 | **取决于你的 cURL**（裸调实测为 200 + 空体，见 `FINDINGS-xuezhijian-wuxi.md`） |
