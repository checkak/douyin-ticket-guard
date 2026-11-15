import SwiftUI
import UIKit

/// 对应视频 0:26 那一页：粘贴抖音订单链接 / cURL / HAR → 提取凭据与商品ID。
struct ImportView: View {
    @EnvironmentObject var store: Store
    @State private var text: String = ""
    @State private var result: ImportParser.Result?
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("粘贴抖音订单链接 / cURL / HAR。\n· cURL → 直接提取 Cookie，可拉库存\n· HAR → 挑出 get_show_sku_info 条目\n· 订单链接 → 提取商品ID、场次、价格")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("抓包内容") {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                    HStack {
                        Button("从剪贴板读取") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                        Spacer()
                        Button("解析") { parse() }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.isEmpty)
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
                    }
                    if !r.productID.isEmpty {
                        Section {
                            Button("用该商品建任务（先不启用）") {
                                store.quickAdd(productID: r.productID,
                                               name: "", session: r.session)
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

    private func parse() {
        result = store.importText(text)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var probeResult: String = ""

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

                Section("深链探测") {
                    Text("哪个方式能落到「确认订单」，就在任务里选哪个。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(previewLinks, id: \.0) { item in
                        Button(item.0) {
                            DeepLink.open(item.1)
                        }
                        .font(.caption)
                    }
                    if !probeResult.isEmpty {
                        Text(probeResult).font(.caption).foregroundStyle(.green)
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

    private var previewLinks: [(String, URL)] {
        guard let first = store.tasks.first else { return [] }
        return DeepLink.candidates(productID: first.productID, session: first.session,
                                   sku: first.skuName, count: first.count)
            .filter { $0.0.hasPrefix("douyin_lite") }
    }
}
