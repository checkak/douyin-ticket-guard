import Foundation
import UIKit
import WebKit

/// 用 WKWebView 打开抖音生活服务落地页，把签名交给页面里的 `sdk-glue` 去做。
///
/// 依据（来自 H5 bundle `trade_detail.js` 的实证）：
///     sI = "https://life.scsjsd.com"
///     ky.A3.setConfig({aid:803772, certType:"header", signVersion:2,
///                      namespace:"web", scene:"web_protect",
///                      consumerPathList:["/aweme/v2/poi/user/trade/product/info/"]})
///     ky.A3.auto({hookFetch:!0, hookXhr:!0}); ky.A3.start();
///     // 业务参数：{ product_id: activity_id, page_type: "h5" }
///
/// 结论：签名只对白名单路径生效、且写在 **请求头** 里。
/// 所以只要在「已加载该页面的 WKWebView」上下文里 fetch 那个路径，
/// SDK 就会自动补签 —— 我们既不逆向算法，也不需要抓包。
@MainActor
final class WebTicketEngine: NSObject, ObservableObject {

    var onLog: ((String, String) -> Void)?          // level, message
    var onStatus: ((String) -> Void)?
    var onSkus: (([Sku]) -> Void)?
    var onMeta: ((ApiClient.Meta) -> Void)?

    private var webView: WKWebView?
    private var pollURL: String?
    private var intervalMs: Double = 1500
    private var tickCount = 0
    private var lastBodyPreview = ""
    private var landedURL = ""

    /// 与 App 内 webview 一致的 UA —— 分享页据此决定是否渲染商品详情
    static let awemeUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 " +
        "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"

    static let apiOrigin = "https://life.scsjsd.com"
    static let infoPath = "/aweme/v2/poi/user/trade/product/info/"

    // MARK: - 生命周期

    func start(landingURL: URL, interval: Double) {
        stop()
        intervalMs = max(800, interval * 1000)
        landedURL = landingURL.absoluteString

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()
        cfg.applicationNameForUserAgent = "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"

        let ucc = WKUserContentController()
        ucc.add(self, name: "dtg")
        ucc.addUserScript(WKUserScript(source: WebTicketEngine.hookScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: -3000, width: 420, height: 900),
                           configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = WebTicketEngine.awemeUA
        wv.alpha = 0.01
        wv.isOpaque = false

        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            win.addSubview(wv)
        }

        webView = wv
        pollURL = WebTicketEngine.infoURL(landing: landingURL)
        onStatus?("加载页面…")
        onLog?("INFO", "网页引擎启动 \(landingURL.absoluteString.prefix(80))")
        if let p = pollURL {
            onLog?("INFO", "准备请求 \(p.prefix(120))")
        }
        wv.load(URLRequest(url: landingURL, timeoutInterval: 25))
    }

    func stop() {
        webView?.evaluateJavaScript("window.__dtg_stop && window.__dtg_stop();")
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dtg")
        webView?.removeFromSuperview()
        webView = nil
        pollURL = nil
        tickCount = 0
    }

    /// 从落地页 URL 里拼出 info 接口地址（product_id = activity_id，page_type=h5）
    static func infoURL(landing: URL) -> String? {
        let comps = URLComponents(url: landing, resolvingAgainstBaseURL: false)
        let q = comps?.queryItems ?? []
        func value(_ names: [String]) -> String? {
            for n in names {
                if let v = q.first(where: { $0.name == n })?.value, !v.isEmpty { return v }
            }
            return nil
        }
        guard let aid = value(["activity_id", "product_id", "show_id", "id"]) else {
            return nil
        }
        var out = [URLQueryItem(name: "product_id", value: aid),
                   URLQueryItem(name: "activity_id", value: aid),
                   URLQueryItem(name: "page_type", value: "h5")]
        if let poi = value(["poi_id"]) { out.append(URLQueryItem(name: "poi_id", value: poi)) }
        if let st = value(["sign_token"]) { out.append(URLQueryItem(name: "sign_token", value: st)) }
        if let sc = value(["sale_channel"]) { out.append(URLQueryItem(name: "sale_channel", value: sc)) }
        if let rp = value(["request_params"]) { out.append(URLQueryItem(name: "request_params", value: rp)) }
        var c = URLComponents(string: apiOrigin + infoPath)!
        c.queryItems = out
        return c.url?.absoluteString
    }

    // MARK: - 处理页面消息

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case "ready":
            let href = msg["href"] as? String ?? ""
            onStatus?("页面就绪")
            onLog?("DEBUG", "页面就绪 \(href.prefix(70))")

        case "sdk":
            let s = msg["state"] as? String ?? "?"
            onLog?("DEBUG", "风控 SDK 状态：\(s)")

        case "captured":
            let url = msg["url"] as? String ?? ""
            let status = msg["status"] as? Int ?? 0
            let size = msg["size"] as? Int ?? 0
            onLog?("DEBUG", "请求 \(status) \(size)B \(url.suffix(60))")

        case "response":
            let url = msg["url"] as? String ?? ""
            let body = msg["body"] as? String ?? ""
            let status = msg["status"] as? Int ?? 0
            guard url.contains("/product/info") || url.contains("get_show_sku_info")
                    || url.contains("/trade/product/") else { return }
            ingest(body: body, url: url, status: status)

        case "error":
            onLog?("ERR", "页面 JS：\((msg["message"] as? String ?? "").prefix(120))")

        default:
            break
        }
    }

    private func ingest(body: String, url: String, status: Int) {
        if body.isEmpty {
            onLog?("WARN", "HTTP \(status) 响应体为空（\(url.suffix(40))）")
            return
        }
        if !body.contains("sku") && !body.contains("stock") && !body.contains("price") {
            if body != lastBodyPreview {
                lastBodyPreview = body
                onLog?("WARN", "响应里没票档字段，前 120 字：\(body.prefix(120))")
            }
            return
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            onLog?("ERR", "响应不是 JSON：\(body.prefix(100))")
            return
        }
        let skus = ApiClient.extractSkus(obj)
        let meta = ApiClient.extractMeta(obj)
        if !meta.isEmpty { onMeta?(meta) }
        if !skus.isEmpty {
            onStatus?("已拿到 \(skus.count) 个票档")
            onLog?("INFO", "票档 " + skus.prefix(6).map { "\($0.name):\($0.stock)" }
                .joined(separator: " / "))
            onSkus?(skus)
        } else {
            onLog?("WARN", "解析不出票档，键名：\(meta.rawKeys.prefix(14).joined(separator: ","))")
        }
    }

    // MARK: - 主动轮询（页面上下文里 fetch，由 SDK 补签）

    private func startPolling(after delay: Double = 2.0) {
        guard let url = pollURL else {
            onLog?("ERR", "落地页 URL 里没有 activity_id，无法构造请求")
            return
        }
        let js = "setTimeout(function(){ window.__dtg_poll && window.__dtg_poll(\(jsStr(url)), \(Int(intervalMs))); }, \(Int(delay * 1000)));"
        webView?.evaluateJavaScript(js) { _, err in
            if let err {
                self.onLog?("ERR", "启动轮询失败：\(err.localizedDescription)")
            } else {
                self.onLog?("INFO", "已下发轮询（\(Int(self.intervalMs))ms，延迟 \(Int(delay))s 等 SDK 就绪）")
            }
        }
    }

    private func jsStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())          // 去掉外层 []
    }

    // MARK: - 注入脚本

    static let hookScript = """
    (function(){
      if (window.__dtg_hooked) { return; }
      window.__dtg_hooked = true;
      function post(p){ try { window.webkit.messageHandlers.dtg.postMessage(p); } catch(e){} }

      var WANT = ['/product/info', 'get_show_sku_info', '/trade/product/'];
      function hit(u){ u = String(u || ''); for (var i=0;i<WANT.length;i++){ if (u.indexOf(WANT[i]) >= 0) return true; } return false; }

      // ---- XHR ----
      var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__dtg_url = u; return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        x.addEventListener('load', function(){
          try {
            var u = String(x.__dtg_url || '');
            var t = x.responseText || '';
            if (hit(u)) {
              post({ type:'captured', url:u, status:x.status, size:t.length });
              if (t) { post({ type:'response', url:u, status:x.status, body:t.slice(0,400000) }); }
            }
          } catch(e){}
        });
        return XS.apply(this, arguments);
      };

      // ---- fetch ----
      var F = window.fetch;
      if (F) {
        window.fetch = function(input, init){
          var u = (typeof input === 'string') ? input : ((input && input.url) || '');
          try {
            if (hit(u)) { post({ type:'captured', url:u, status:0, size:-1 }); }
          } catch(e){}
          return F.apply(this, arguments).then(function(res){
            try {
              if (hit(u)) {
                res.clone().text().then(function(t){
                  post({ type:'response', url:u, status:res.status, body:(t||'').slice(0,400000) });
                }).catch(function(){});
              }
            } catch(e){}
            return res;
          });
        };
      }

      // ---- 主动轮询 ----
      window.__dtg_poll = function(url, intervalMs){
        window.__dtg_stop();
        var hit0 = function(){
          try {
            fetch(url, { credentials: 'include' })
              .then(function(r){
                return r.text().then(function(t){
                  post({ type:'response', url:url, status:r.status, body:(t||'').slice(0,400000) });
                });
              })
              .catch(function(e){ post({ type:'error', message:'poll fetch: ' + e }); });
          } catch(e){ post({ type:'error', message:'poll: ' + e }); }
        };
        hit0();
        window.__dtg_timer = setInterval(hit0, Math.max(800, intervalMs || 1500));
      };
      window.__dtg_stop = function(){
        if (window.__dtg_timer) { clearInterval(window.__dtg_timer); window.__dtg_timer = null; }
      };

      // ---- 探测风控 SDK 是否起来（A3 = sdk-glue 的实例名）----
      var probe = function(){
        var st = [];
        try { st.push('ky:' + (typeof window.ky)); } catch(e){}
        try { st.push('A3:' + (window.ky && window.ky.A3 ? 'yes' : 'no')); } catch(e){}
        st.push('hookedXhr:' + (XMLHttpRequest.prototype.open !== XO ? 'yes' : 'no'));
        post({ type:'sdk', state: st.join(' ') });
      };
      setTimeout(probe, 1500);
      setTimeout(probe, 4000);

      window.addEventListener('error', function(e){
        post({ type:'error', message: String(e && e.message || '') });
      });
      post({ type:'ready', href: location.href });
    })();
    """
}

// MARK: - WKScriptMessageHandler / NavigationDelegate

extension WebTicketEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        handle(dict)
    }
}

extension WebTicketEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onStatus?("页面加载完成")
        onLog?("INFO", "页面已加载：\(webView.url?.absoluteString.prefix(90) ?? "-")")
        startPolling()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLog?("ERR", "页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onLog?("ERR", "页面预加载失败：\(error.localizedDescription)")
        // 落地页 404/重定向到首页时，退一步用构造函数直接试
        if let pid = WebTicketEngine.landingFallback(from: landedURL),
           let u = URL(string: pid), webView.url == nil {
            onLog?("INFO", "改用备用落地页：\(u.absoluteString.prefix(80))")
            webView.load(URLRequest(url: u))
        }
    }

    /// 兜底落地页（去掉 share 参数，只留 activity_id）
    static func landingFallback(from: String) -> String? {
        guard let url = URL(string: from),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let aid = comps.queryItems?.first(where: {
            ["activity_id", "product_id", "id"].contains($0.name) })?.value else { return nil }
        return "https://life.scsjsd.com/falcon/poi_mwa/trade_detail?app=aweme&source=groupbuy"
            + "&is_share_page=1&hide_nav_bar=1&should_full_screen=1&activity_id=\(aid)"
    }
}
