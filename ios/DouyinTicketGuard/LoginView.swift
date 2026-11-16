import SwiftUI
import WebKit

/// 登录用的 WebView：与监控引擎共用 `WKWebsiteDataStore.default()`，
/// 并注入同一套 hook 脚本 —— 这样页面登录后自己发出的 `product/info`
/// 响应会被立刻截获，用来当场验证「登录态到底生效没有」。
struct LoginWebView: UIViewRepresentable {
    let startURL: URL
    var onStatus: (String) -> Void
    var onCapture: (String, String) -> Void      // (url, body)

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.applicationNameForUserAgent = "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "dtg")
        ucc.addUserScript(WKUserScript(source: WebTicketEngine.hookScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = WebTicketEngine.awemeUA
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: startURL, timeoutInterval: 25))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus, onCapture: onCapture)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onStatus: (String) -> Void
        let onCapture: (String, String) -> Void

        init(onStatus: @escaping (String) -> Void, onCapture: @escaping (String, String) -> Void) {
            self.onStatus = onStatus
            self.onCapture = onCapture
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let d = message.body as? [String: Any],
                  let type = d["type"] as? String else { return }
            if type == "response" {
                let url = d["url"] as? String ?? ""
                let body = d["body"] as? String ?? ""
                if url.contains("product/info") || url.contains("/trade/product/") {
                    onCapture(url, body)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onStatus("已加载 \(webView.url?.host ?? "-")")
            // 页面上常有「登录/注册」入口，自动点一下
            let js = """
            (function(){
              var n = document.querySelectorAll('div,span,button,a');
              for (var i=0;i<n.length;i++){
                var t=(n[i].textContent||'').trim();
                if (t.length<=6 && /登录|立即登录/.test(t)) { try{ n[i].click(); return 'clicked'; }catch(e){} }
              }
              return 'none';
            })();
            """
            webView.evaluateJavaScript(js) { v, _ in
                if let s = v as? String, s == "clicked" {
                    self.onStatus("已自动点开登录入口")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onStatus("加载失败：\(error.localizedDescription)")
        }
    }
}

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store

    @State private var urlText: String = ""
    @State private var currentURL: URL?
    @State private var status: String = ""
    @State private var captured = 0
    @State private var lastEmpty = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在这个页面里登录（手机号验证码）。登录成功后页面会自动请求票档接口，"
                         + "日志会告诉你拿到几个票档——这就是「登录态生效」的直接证据。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("落地页 URL", text: $urlText)
                            .font(.system(.caption2, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("打开") { load(urlText) }
                            .font(.caption)
                    }
                    HStack(spacing: 8) {
                        Button("演出落地页") { load(defaultLanding) }
                        Button("抖音首页") { load("https://www.douyin.com/") }
                        Spacer()
                        Text(status).font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .padding(10)

                if let u = currentURL {
                    LoginWebView(startURL: u,
                                 onStatus: { s in status = s; store.addLog(.dbg, "[登录] \(s)") },
                                 onCapture: handleCapture)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Spacer()
                    Text("点上面按钮打开页面").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .navigationTitle("登录（演出页域）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("检测并完成") { checkAndDismiss() }
                }
            }
            .onAppear {
                if urlText.isEmpty { urlText = defaultLanding }
                if currentURL == nil { load(urlText) }
            }
        }
    }

    // MARK: - 逻辑

    private var defaultLanding: String {
        if let t = store.tasks.first, !t.landingURL.isEmpty { return t.landingURL }
        if let t = store.tasks.first { return Store.landingURL(for: t.productID) }
        return Store.landingURL(for: "1881078666742800")
    }

    private func load(_ s: String) {
        let t = ImportParser.normalize(s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let u = URL(string: t) else {
            status = "URL 无效"
            return
        }
        currentURL = u
        urlText = t
        captured = 0
        lastEmpty = false
        store.addLog(.info, "[登录] 打开 \(t.prefix(90))")
    }

    private func handleCapture(_ url: String, _ body: String) {
        if body.isEmpty {
            if !lastEmpty {
                lastEmpty = true
                store.addLog(.err, "[登录] product/info 仍返回 0 字节 —— 这个域的登录态还没生效")
            }
            return
        }
        lastEmpty = false
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        let skus = ApiClient.extractSkus(obj)
        let meta = ApiClient.extractMeta(obj)
        captured += 1
        if !meta.isEmpty || !skus.isEmpty {
            store.addLog(.info, "[登录] ✅ 接口已通：\(skus.count) 个票档"
                + (meta.title.isEmpty ? "" : " · \(meta.title)")
                + (meta.session.isEmpty ? "" : " · \(meta.session)"))
            for s in skus.prefix(8) {
                store.addLog(.info, "[登录]    \(s.name)  ¥\(s.priceYuan)  剩余\(s.stock)")
            }
        } else if !meta.rawKeys.isEmpty {
            store.addLog(.info, "[登录] 响应有内容但未解析出票档，键名：\(meta.rawKeys.prefix(12).joined(separator: ","))")
        } else {
            store.addLog(.dbg, "[登录] 响应 \(body.count)B: \(body.prefix(90))")
        }
    }

    private func checkAndDismiss() {
        WebCookieBridge.snapshot { names, logged in
            let key = ["sessionid", "sessionid_ss", "sid_guard", "uid_tt", "d_ticket",
                       "ttwid", "msToken", "sso_uid_tt"]
            let hit = names.filter { key.contains($0) }
            store.addLog(logged ? .info : .err,
                         logged
                         ? "网页容器已登录 ✅ 关键 cookie：\(hit.joined(separator: ", "))"
                         : "网页容器仍未登录 ❌（\(names.count) 个 cookie：\(hit.joined(separator: ", "))）")
            dismiss()
        }
    }
}
