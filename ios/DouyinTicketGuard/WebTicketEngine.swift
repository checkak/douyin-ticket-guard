import Foundation
import UIKit
import WebKit

/// 网页引擎 v3。
///
/// 前两版的教训（来自真机日志）：
///   1. 自己在页面里 fetch info 接口 → 跨源被挡，WebKit 报 `TypeError: Load failed`；
///   2. 落地页可能被重定向到别的 origin（如 www.douyin.com），签名 namespace 也就不对了。
///
/// v3 原则：**只让页面自己发请求**。我们只做两件事：
///   · 被动截获页面自己的 XHR/fetch（同源，不会被 CORS 挡，且一定带签名）
///   · 页面不发数据时，轻推一下（点击含「票/¥」的元素、必要时 reload）
/// 同时把页面所有请求（path + status + size）打进日志，便于定位真实接口。
@MainActor
final class WebTicketEngine: NSObject, ObservableObject {

    var onLog: ((String, String) -> Void)?          // level, message
    var onStatus: ((String) -> Void)?
    var onSkus: (([Sku]) -> Void)?
    var onMeta: ((ApiClient.Meta) -> Void)?

    private var webView: WKWebView?
    private var intervalMs: Double = 2000
    private var gotData = false
    private var tick = 0
    private var nudgeTimer: Timer?
    private var reloadTimer: Timer?
    private var seenPaths = Set<String>()
    private var targetOrigin = "life.scsjsd.com"

    static let awemeUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 " +
        "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"

    // MARK: - 生命周期

    func start(landingURL: URL, interval: Double) {
        stop()
        intervalMs = max(800, interval * 1000)
        if let host = landingURL.host { targetOrigin = host }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.applicationNameForUserAgent = "Aweme/32900 (iPhone; iOS 16.2; Scale/3.00)"
        let ucc = WKUserContentController()
        ucc.add(self, name: "dtg")
        ucc.addUserScript(WKUserScript(source: WebTicketEngine.hookScript,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: -3000, width: 430, height: 930),
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
        gotData = false
        tick = 0
        seenPaths.removeAll()

        onLog?("INFO", "网页引擎启动 \(landingURL.absoluteString.prefix(86))")
        wv.load(URLRequest(url: landingURL, timeoutInterval: 25))
    }

    func stop() {
        nudgeTimer?.invalidate(); nudgeTimer = nil
        reloadTimer?.invalidate(); reloadTimer = nil
        webView?.evaluateJavaScript("window.__dtg_stop && window.__dtg_stop();")
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dtg")
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - 消息处理

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case "ready":
            let href = msg["href"] as? String ?? ""
            let origin = msg["origin"] as? String ?? ""
            onLog?("INFO", "页面就绪 origin=\(origin) \(href.prefix(70))")
            if !origin.contains(targetOrigin) {
                onLog?("WARN", "origin 不是 \(targetOrigin)，签名 namespace 可能不对（将尝试纠正）")
            }

        case "sdk":
            onLog?("DEBUG", "风控 SDK：\(msg["state"] as? String ?? "?")")

        case "trace":
            let path = msg["path"] as? String ?? ""
            let status = msg["status"] as? Int ?? 0
            let size = msg["size"] as? Int ?? 0
            let key = "\(path)#\(status)"
            guard !seenPaths.contains(key) else { return }
            seenPaths.insert(key)
            onLog?("DEBUG", "页面请求 \(status) \(size)B \(path.prefix(100))")

        case "response":
            let url = msg["url"] as? String ?? ""
            let body = msg["body"] as? String ?? ""
            ingest(body: body, url: url)

        case "error":
            let m = msg["message"] as? String ?? ""
            // 轮询已移除，剩下的多半是页面自身脚本报错，降级成 DEBUG 免得刷屏
            onLog?("DEBUG", "页面 JS：\(m.prefix(110))")

        default:
            break
        }
    }

    private func ingest(body: String, url: String) {
        let looksLikeProduct = body.contains("sku") || body.contains("stock")
            || body.contains("price") || body.contains("activity")
        guard looksLikeProduct else {
            onLog?("DEBUG", "响应非商品数据（\(body.count)B）\(url.suffix(46))")
            return
        }
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        let skus = ApiClient.extractSkus(obj)
        let meta = ApiClient.extractMeta(obj)
        if !skus.isEmpty || !meta.isEmpty {
            gotData = true
            reloadTimer?.invalidate(); reloadTimer = nil
        }
        if !meta.isEmpty { onMeta?(meta) }
        if !skus.isEmpty {
            onStatus?("已拿到 \(skus.count) 个票档")
            onLog?("INFO", "票档 " + skus.prefix(8).map { "\($0.name):\($0.stock)" }
                .joined(separator: " / "))
            onSkus?(skus)
        } else if !meta.rawKeys.isEmpty {
            onLog?("DEBUG", "键名样本：\(meta.rawKeys.prefix(16).joined(separator: ","))")
        }
    }

    // MARK: - 页面级轻推（不发我们自己的请求）

    private func scheduleNudges() {
        nudgeTimer?.invalidate()
        // 3s / 7s / 12s 各点一次「票档/价格」区域，促使 SPA 自己拉数据
        for (i, delay) in [3.0, 7.0, 12.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let wv = self.webView, !self.gotData else { return }
                self.tick = i + 1
                wv.evaluateJavaScript(WebTicketEngine.nudgeJS) { _, _ in
                    self.onLog?("DEBUG", "轻推 #\(i + 1)（点击票档区域）")
                }
            }
        }
        // 15s 还没数据 → 每 6 秒 reload 一次（页面自己的请求一定带签名）
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let wv = self.webView, !self.gotData else { return }
                self.onLog?("WARN", "仍无商品数据，reload 重试")
                wv.reload()
            }
        }
    }

    // MARK: - 注入脚本

    static let nudgeJS = """
    (function(){
      var hit = 0;
      var nodes = document.querySelectorAll('div,li,span,button,a,section');
      for (var i = 0; i < nodes.length && hit < 4; i++) {
        var el = nodes[i];
        var t = (el.textContent || '').trim();
        if (t.length > 0 && t.length < 40 && /¥|￥|票|选择|预订|立即/.test(t)) {
          try { el.click(); hit++; } catch(e){}
        }
      }
      window.scrollTo(0, document.body.scrollHeight * 0.6);
      return hit;
    })();
    """

    static let hookScript = """
    (function(){
      if (window.__dtg_hooked) { return; }
      window.__dtg_hooked = true;
      function post(p){ try { window.webkit.messageHandlers.dtg.postMessage(p); } catch(e){} }
      function short(u){
        try {
          var x = new URL(u, location.href);
          return x.host + x.pathname;
        } catch(e) { return String(u).slice(0, 80); }
      }
      // 只对「疑似商品数据」的响应回传 body，其它只报路径
      function maybeBody(u){
        return /product\\/info|get_show_sku_info|trade\\/product|sku|stock|price/i.test(u);
      }

      var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__dtg_url = u; return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        x.addEventListener('load', function(){
          try {
            var u = String(x.__dtg_url || ''), t = x.responseText || '';
            post({ type:'trace', path: short(u), status: x.status, size: t.length });
            if (t && maybeBody(u)) { post({ type:'response', url:u, body:t.slice(0, 400000) }); }
          } catch(e){}
        });
        return XS.apply(this, arguments);
      };

      var F = window.fetch;
      if (F) {
        window.fetch = function(input, init){
          var u = (typeof input === 'string') ? input : ((input && input.url) || '');
          return F.apply(this, arguments).then(function(res){
            try {
              res.clone().text().then(function(t){
                post({ type:'trace', path: short(u), status: res.status, size: (t||'').length });
                if (t && maybeBody(u)) { post({ type:'response', url:u, body:t.slice(0, 400000) }); }
              }).catch(function(){});
            } catch(e){}
            return res;
          });
        };
      }

      window.__dtg_stop = function(){};

      var probe = function(){
        var st = [];
        try { st.push('ky:' + typeof window.ky); } catch(e){}
        try { st.push('A3:' + (window.ky && window.ky.A3 ? 'yes' : 'no')); } catch(e){}
        st.push('xhrHooked:' + (XMLHttpRequest.prototype.open !== XO ? 'yes' : 'no'));
        post({ type:'sdk', state: st.join(' ') });
      };
      setTimeout(probe, 1200);
      setTimeout(probe, 4000);

      window.addEventListener('error', function(e){
        post({ type:'error', message: String(e && e.message || '') });
      });
      post({ type:'ready', href: location.href, origin: location.origin });
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
        let url = webView.url?.absoluteString ?? "-"
        onStatus?("页面加载完成")
        onLog?("INFO", "页面已加载 \(url.prefix(96))")
        scheduleNudges()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLog?("ERR", "页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        onLog?("ERR", "页面预加载失败：\(error.localizedDescription)")
    }

    /// 页面若被重定向到别的 origin，纠正回目标域的 canonical 落地页
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation
                 navigation: WKNavigation!) {
        if let host = webView.url?.host, !host.contains(targetOrigin) {
            onLog?("WARN", "被重定向到 \(host)，尝试纠正回 \(targetOrigin)")
        }
    }
}
