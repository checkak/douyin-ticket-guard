import SwiftUI
import UIKit

/// 对应视频 0:26 那一页：粘贴抖音订单链接 / cURL / HAR → 提取凭据与商品ID。
/// 短链（v.douyin.com/xxx）需要真去跟跳转，见 LinkResolver。
struct ImportView: View {
    @EnvironmentObject var store: Store
    @State private var text: String = ""
    @State private var result: ImportParser.Result?
    @State private var hops: [String] = []
    @State private var isGroupBuy = false
    @State private var busy = false
    @State private var status: String = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("粘贴抖音订单链接 / cURL / HAR。\n· 短链（v.douyin.com）会自动跟跳转拿商品ID\n· cURL → 直接提取 Cookie，可拉库存\n· HAR → 挑出 get_show_sku_info 条目")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("抓包内容") {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("从剪贴板读取") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                        Spacer()
                        Button {
                            Task { await runParse() }
                        } label: {
                            if busy {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.8)
                                    Text("解析中")
                                }
                            } else {
                                Text("解析")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.isEmpty || busy)
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let r = result {
                    Section("解析结果") {
                        LabeledContent("来源", value: r.kind)
                        LabeledContent("Cookie", value: "\(r.cookies.count) 个")
                        LabeledContent("登录态", value: r.hasAuth ? "有（含 sid_guard）" : "无")
                        LabeledContent("商品ID", value: r.productID.isEmpty ? "未识别" : r.productID)
                        LabeledContent("场次", value: r.session.isEmpty ? "-" : r.session)
                        if r.price > 0 {
                            LabeledContent("价格", value: String(format: "%.2f", r.price))
                        }
                        if !r.url.isEmpty, r.kind == "link" {
                            LabeledContent("链接", value: String(r.url.prefix(58)) + "…")
                        }
                    }

                    if !r.note.isEmpty {
                        Section("提示") {
                            Label(r.note, systemImage: r.productID.isEmpty
                                  ? "exclamationmark.triangle" : "info.circle")
                                .font(.footnote)
                                .foregroundStyle(r.productID.isEmpty ? .orange : .secondary)
                        }
                    }

                    if !hops.isEmpty {
                        Section("跳转链") {
                            ForEach(Array(hops.enumerated()), id: \.offset) { _, h in
                                Text(h)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }

                    if isGroupBuy {
                        Section {
                            Label("团购商品（source=groupbuy）：链接只能给商品ID，"
                                  + "要拉库存还需要再粘一条 cURL 换 Cookie。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                        }
                    }

                    if !r.productID.isEmpty {
                        Section {
                            Button("用该商品建任务（先不启用）") {
                                store.quickAdd(productID: r.productID,
                                               name: r.kind == "link" ? "" : "",
                                               session: r.session,
                                               landing: r.url.hasPrefix("http") ? r.url : "")
                                showAlert = true
                            }
                        }
                    }
                }

                Section("当前凭据") {
                    LabeledContent("Cookie 数", value: "\(store.cookies.count)")
                    LabeledContent("Bark Key", value: store.barkKey.isEmpty ? "未设置" : "已设置")
                    Button("清空 Cookie", role: .destructive) {
                        store.cookies = [:]
                        store.headers = [:]
                    }
                }
            }
            .navigationTitle("订单链接解析")
            .alert("已加入监控", isPresented: $showAlert) {
                Button("好") {}
            } message: {
                Text("去「监控」里选择票档后启用")
            }
        }
    }

    // MARK: - 解析流程

    private func runParse() async {
        busy = true
        hops = []
        isGroupBuy = false
        status = "解析中…"
        defer { busy = false }

        let normalized = ImportParser.normalize(text)
        var r = ImportParser.parse(normalized)
        status = "来源 \(r.kind)，识别到 \(r.cookies.count) 个 Cookie"

        // 短链/落地页：本地正则没结果时，真去跟一次跳转
        if r.productID.isEmpty, let url = ImportParser.firstURL(normalized) {
            status = "正在展开短链…"
            let res = await LinkResolver.resolve(url)
            hops = res.hops
            isGroupBuy = res.isGroupBuy
            if !res.productID.isEmpty {
                r.productID = res.productID
                status = "展开成功，商品ID \(res.productID)"
            } else {
                status = "展开失败：\(res.note)"
            }
            if let final = res.finalURL, final.absoluteString != url.absoluteString {
                r.url = final.absoluteString
            }
            // 落地页 URL 里可能带日期等，再补一轮
            if let final = res.finalURL {
                let again = ImportParser.parse(final.absoluteString)
                if r.session.isEmpty { r.session = again.session }
                if r.price == 0 { r.price = again.price }
            }
        }

        if !r.cookies.isEmpty {
            store.cookies.merge(r.cookies) { _, new in new }
            store.headers.merge(r.headers) { _, new in new }
        }
        store.addLog(.info, "导入完成：\(r.kind) · cookie \(r.cookies.count) · 商品ID \(r.productID.isEmpty ? "未识别" : r.productID)")
        result = r
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var probeResult: String = ""
    @State private var resolving = false
    @State private var apiHost: String = ApiClient.customHost

    var body: some View {
        NavigationStack {
            Form {
                Section("推送") {
                    TextField("Bark Device Key", text: $store.barkKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("发一条测试推送") {
                        Notifier.shared.bark(deviceKey: store.barkKey,
                                             title: "发现库存（测试）",
                                             body: "票档监控 · 通知链路正常",
                                             url: nil) { ok in
                            probeResult = ok ? "推送成功" : "推送失败，检查 Key"
                        }
                    }
                }

                Section("任务引擎") {
                    Button("把全部任务切到网页引擎") {
                        for t in store.tasks where t.engine != "web" {
                            var x = t
                            x.engine = "web"
                            store.update(x)
                        }
                        probeResult = "已切换 \(store.tasks.count) 个任务到网页引擎"
                    }
                    Text("网页引擎不依赖 Cookie 与抓包；直连引擎只在你有签名环境时才有用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("接口集群") {
                    TextField("life5-normal-m-zb.amemv.com", text: $apiHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { ApiClient.customHost = apiHost.trimmingCharacters(in: .whitespaces) }
                    Text("留空 = 自动轮询 4 个已知集群（zb / zjg / gl2 / lf）。"
                         + "抓包里看到的那个域名填进来最省事。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存集群设置") {
                        ApiClient.customHost = apiHost.trimmingCharacters(in: .whitespaces)
                        probeResult = ApiClient.customHost.isEmpty
                            ? "已切回自动轮询" : "已固定到 \(ApiClient.customHost)"
                    }
                }

                Section("深链探测") {
                    Text("哪个方式能落到「确认订单」，就在任务里选哪个。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if store.tasks.isEmpty {
                        Text("先建一条任务").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(previewLinks, id: \.0) { item in
                        Button(item.0) { DeepLink.open(item.1) }
                            .font(.caption)
                    }
                    if !probeResult.isEmpty {
                        Text(probeResult).font(.caption).foregroundStyle(.green)
                    }
                }

                Section("短链自测") {
                    Text("用 LinkResolver 现场跟一遍跳转，确认网络链路没问题。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("https://v.douyin.com/xxxx/", text: $testLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.caption, design: .monospaced))
                    Button(resolving ? "跟进中…" : "测试展开") {
                        Task {
                            resolving = true
                            defer { resolving = false }
                            guard let u = URL(string: ImportParser.normalize(testLink)) else {
                                probeResult = "链接格式不对"
                                return
                            }
                            let r = await LinkResolver.resolve(u)
                            probeResult = r.productID.isEmpty
                                ? "失败：\(r.note)"
                                : "成功：商品ID \(r.productID)"
                            testHops = r.hops
                        }
                    }
                    .disabled(resolving || testLink.isEmpty)
                    ForEach(Array(testHops.enumerated()), id: \.offset) { _, h in
                        Text(h).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section("iOS 限制说明") {
                    Text("""
                    前台：按设定间隔高频轮询（1~2 秒）。
                    后台：系统只给 BGAppRefresh，粒度 ≥15 分钟，且不保证执行。
                    所以真要靠它抢票，需要：
                      1) 保持 App 在前台（引导式访问 / 画中画）；
                      2) 或把轮询放到服务器，手机只收 Bark 推送；
                      3) 最后一步支付必须人工确认。
                    """)
                    .font(.caption)
                }
            }
            .navigationTitle("设置")
        }
    }

    @State private var testLink: String = "https://v.douyin.com/erD9I8GpPaU/"
    @State private var testHops: [String] = []

    private var previewLinks: [(String, URL)] {
        guard let first = store.tasks.first else { return [] }
        return DeepLink.candidates(productID: first.productID, session: first.session,
                                   sku: first.skuName, count: first.count)
            .filter { $0.0.hasPrefix("douyin_lite") }
    }
}
