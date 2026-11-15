import SwiftUI
import WebKit

/// App 内置登录：在同一个 WKWebsiteDataStore.default() 里打开抖音 H5 登录。
/// 登录一次后 cookie 持久化，之后监控引擎（同一个 data store）发出的 product/info
/// 就会带上 h5_user_id，服务端才会返回 sku_list / 库存 / 场次 / 价格。
struct DouyinLoginView: UIViewRepresentable {
    let startURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.applicationNameForUserAgent = "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = WebTicketEngine.awemeUA
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: startURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[login] 已加载 \(webView.url?.absoluteString ?? "-")")
        }
    }
}

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在这个页面里登录一次抖音（手机号验证码 / 密码 / 扫码都行）。"
                     + "登录态会保存在 App 内，之后监控就不用再登录了。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)

                DouyinLoginView(startURL: URL(string: "https://www.douyin.com/")!)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("登录抖音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("已登录") {
                        store.addLog(.info, "登录流程结束，开始监控时会在同一 data store 里请求接口")
                        dismiss()
                    }
                }
            }
        }
    }
}
