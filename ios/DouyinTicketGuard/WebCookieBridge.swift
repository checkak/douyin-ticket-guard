import Foundation
import WebKit

/// 把 Cookie 注入 WKWebView 的共享 cookie 存储。
///
/// 为什么需要：`poi/public/detail_web` 会返回 `need_login: true`，
/// `product/info` 不带登录态直接 200 + 0 字节。
/// 只要把用户自己的 Cookie（sessionid / sid_guard / uid_tt / d_ticket …）
/// 写进 `WKWebsiteDataStore.default()`，隐藏的监控 WebView 发出的请求就带登录态了。
enum WebCookieBridge {

    static let domains = [".douyin.com", ".snssdk.com", ".amemv.com",
                          ".scsjsd.com", ".bytedance.com"]

    /// 注入并回传成功写入的条数
    static func install(_ cookies: [String: String], completion: @escaping (Int) -> Void) {
        guard !cookies.isEmpty else { completion(0); return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var written = 0
        let group = DispatchGroup()
        for (name, value) in cookies {
            for domain in domains {
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: domain,
                    .path: "/",
                    .expires: Date().addingTimeInterval(60 * 60 * 24 * 7),
                ]
                if domain == ".douyin.com" { props[.secure] = "TRUE" }
                guard let cookie = HTTPCookie(properties: props) else { continue }
                group.enter()
                store.setCookie(cookie) {
                    written += 1
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(written) }
    }

    /// 检查网页容器里的登录态（sessionid 是关键项）
    static func snapshot(completion: @escaping ([String], Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let names = cookies.map { $0.name }
            let logged = names.contains("sessionid") || names.contains("sessionid_ss")
                || names.contains("sid_guard")
            completion(Array(Set(names)).sorted(), logged)
        }
    }

    static func clear(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: Date(timeIntervalSince1970: 0)) {
            completion()
        }
    }
}
