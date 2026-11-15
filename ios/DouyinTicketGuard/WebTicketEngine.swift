import Foundation
import UIKit
import WebKit

/// 用 WKWebView 跑抖音活动落地页，让「页面自己」去请求 product/info。
///
/// 为什么这样做：`sdk-glue.js` 会全局劫持 `XMLHttpRequest.prototype`，
/// 页面里任何 XHR 都会被自动补上 msToken / a_bogus 一类签名参数。
/// 所以不伪造签名、不逆向算法——只把页面发出的响应截下来。
///
/// 轮询：把首次捕获到的「已签名 URL + 请求头」原样重放（复用页面同一个 XHR 通道）。
/// 若重放拿不到数据，退化为 `location.reload()` 定时刷新。
@MainActor
final class WebTicketEngine: NSObject, ObservableObject {

    // 回调
    var onLog: ((String, String) -> Void)?          // level, message
    var onStatus: ((String) -> Void)?
    var onSkus: (([Sku]) -> Void)?
    var onMeta: ((ApiClient.Meta) -> Void)?

    private var webView: WKWebView?
    private var pollURL: String?
    private var pollHeaders: [String: String] = [:]
    private var intervalMs: Double = 1500
    private var sawResponse = false
    private var reloadTimer: Timer?

    private static let pollPathHints = ["product/info", "get_show_sku_info", "trade/product"]

    // MARK: - 生命周期

    func start(landingURL: URL, interval: Double) {
        stop()
        intervalMs = max(500, interval * 1000)

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.add(self, name: "dtg")
        let js = WebTicketEngine.hookScript
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: -3000, width: 420, height: 900),
                           configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        wv.alpha = 0.01
        wv.isOpaque = false

        // 必须挂进视图层级，否则 JS 定时器在后台容易被节流/挂起
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let win = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            win.addSubview(wv)
        }

        webView = wv
        sawResponse = false
        pollURL = nil
        onStatus?("加载页面…")
        onLog?("INFO", "网页引擎启动：\(landingURL.absoluteString.prefix(90))")
        wv.load(URLRequest(url: landingURL, timeoutInterval: 25))
    }

    func stop() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        webView?.evaluateJavaScript("window.__dtg_stop && window.__dtg_stop();")
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dtg")
        webView?.removeFromSuperview()
        webView = nil
        pollURL = nil
    }

    // MARK: - 处理页面消息

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case "ready":
            let href = msg["href"] as? String ?? ""
            onStatus?("页面就绪")
            onLog?("DEBUG", "页面就绪 \(href.prefix(80))")

        case "request":
            let url = msg["url"] as? String ?? ""
            guard WebTicketEngine.pollPathHints.contains(where: { url.contains($0) }) else { return }
            if pollURL == nil {
                pollURL = url
                pollHeaders = (msg["headers"] as? [String: String]) ?? [:]
                onLog?("INFO", "捕获到接口：\(url.prefix(110))")
                startPolling()
            }

        case "response":
            let url = msg["url"] as? String ?? ""
            let body = msg["body"] as? String ?? ""
            guard WebTicketEngine.pollPathHints.contains(where: { url.contains($0) }) else { return }
            if body.isEmpty {
                onLog?("WARN", "响应体为空（该请求未带签名或已被风控拒绝）")
                return
            }
            ingest(body: body, url: url)

        case "error":
            onLog?("ERR", "页面 JS 报错：\((msg["message"] as? String ?? "").prefix(140))")

        default:
            break
        }
    }

    private func ingest(body: String, url: String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            onLog?("ERR", "响应不是 JSON：\(body.prefix(80))")
            return
        }
        sawResponse = true
        let skus = ApiClient.extractSkus(obj)
        let meta = ApiClient.extractMeta(obj)
        onStatus?("已拿到数据：\(skus.count) 个票档")
        if !meta.title.isEmpty || !meta.session.isEmpty {
            onMeta?(meta)
        }
        if !skus.isEmpty {
            onLog?("INFO", "票档 " + skus.prefix(6).map { "\($0.name):\($0.stock)" }
                .joined(separator: " / "))
            onSkus?(skus)
        } else {
            onLog?("WARN", "响应里没解析出票档，键名：\(meta.rawKeys.prefix(12).joined(separator: ","))")
        }
        if pollURL == nil {
            pollURL = url
            startPolling()
        }
    }

    private func startPolling() {
        guard let url = pollURL, let wv = webView else { return }
        let headers = pollHeaders
        let payload = (try? JSONSerialization.data(withJSONObject: [url, headers, intervalMs]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let js = "window.__dtg_poll && window.__dtg_poll(\(payload)[0], \(payload)[1], \(payload)[2]);"
        wv.evaluateJavaScript(js) { _, err in
            if let err {
                self.onLog?("ERR", "启动轮询失败：\(err.localizedDescription)")
            } else {
                self.onLog?("INFO", "网页轮询已启动，间隔 \(Int(self.intervalMs))ms")
            }
        }

        // 兜底：如果 20 秒内一次有效响应都没有，改为定时刷新页面
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let wv = self.webView else { return }
                if self.sawResponse {
                    self.sawResponse = false      // 下一轮再看是否持续有数据
                    return
                }
                self.onLog?("WARN", "20s 无有效响应，改为刷新页面")
                wv.reload()
            }
        }
    }

    // MARK: - 注入脚本

    static let hookScript = """
    (function(){
      if (window.__dtg_hooked) { return; }
      window.__dtg_hooked = true;
      var post = function(p){ try { window.webkit.messageHandlers.dtg.postMessage(p); } catch(e){} };

      // ---- XHR 发送时上报（拿已签名的 URL 与请求头）----
      var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send,
          SH = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function(m, u){
        this.__dtg = { m: m, u: u, h: {} };
        return XO.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(k, v){
        try { if (this.__dtg) { this.__dtg.h[k] = v; } } catch(e){}
        return SH.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(){
        var self = this;
        try {
          if (this.__dtg) {
            post({ type: 'request', url: String(this.__dtg.u), headers: this.__dtg.h });
          }
        } catch(e){}
        this.addEventListener('load', function(){
          try {
            var u = (self.__dtg && self.__dtg.u) || '';
            var t = self.responseText || '';
            if (t) { post({ type: 'response', url: String(u), body: t.slice(0, 400000) }); }
          } catch(e){}
        });
        return XS.apply(this, arguments);
      };

      // ---- fetch 也一并抓 ----
      var F = window.fetch;
      if (F) {
        window.fetch = function(input, init){
          var u = (typeof input === 'string') ? input : ((input && input.url) || '');
          var h = (init && init.headers) || {};
          try { post({ type: 'request', url: String(u), headers: h }); } catch(e){}
          return F.apply(this, arguments).then(function(res){
            try {
              res.clone().text().then(function(t){
                if (t) { post({ type: 'response', url: String(u), body: t.slice(0, 400000) }); }
              }).catch(function(){});
            } catch(e){}
            return res;
          });
        };
      }

      // ---- 轮询器：原样重放页面自己签过名的请求 ----
      window.__dtg_poll = function(url, headers, intervalMs){
        window.__dtg_stop();
        var hit = function(){
          try {
            var x = new XMLHttpRequest();
            x.open('GET', url, true);
            Object.keys(headers || {}).forEach(function(k){
              try { x.setRequestHeader(k, headers[k]); } catch(e){}
            });
            x.send();
          } catch(e){}
        };
        hit();
        window.__dtg_timer = setInterval(hit, Math.max(500, intervalMs || 1500));
      };
      window.__dtg_stop = function(){
        if (window.__dtg_timer) { clearInterval(window.__dtg_timer); window.__dtg_timer = null; }
      };

      window.addEventListener('error', function(e){
        post({ type: 'error', message: String(e && e.message || '') });
      });

      post({ type: 'ready', href: location.href });
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
        // 页面若没主动请求，就点一下「查看票档」之类不会生效，这里只做日志
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        onLog?("ERR", "页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onLog?("ERR", "页面预加载失败：\(error.localizedDescription)")
    }
}
