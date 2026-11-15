import Foundation
import UIKit

/// 深链构造：把「商品ID + 票档 + 人数」变成能落到订单页的 URL。
/// 抖音 scheme 无公开文档，所以给候选表 + 探测（对应 dg probe）。
enum DeepLink {

    static func showH5(productID: String, session: String, sku: String, count: Int) -> String {
        var comps = URLComponents(string: "https://life.douyin.com/p/show/detail")!
        var q: [URLQueryItem] = [URLQueryItem(name: "product_id", value: productID)]
        if !session.isEmpty { q.append(URLQueryItem(name: "session_time", value: session)) }
        if !sku.isEmpty { q.append(URLQueryItem(name: "sku_name", value: sku)) }
        q.append(URLQueryItem(name: "buy_count", value: String(count)))
        comps.queryItems = q
        return comps.url?.absoluteString ?? "https://life.douyin.com/"
    }

    static func build(kind: String, productID: String, session: String,
                      sku: String, count: Int, app: String = "douyin_lite") -> URL? {
        let scheme = (app == "douyin") ? "snssdk1128" : "douyinlite"
        let inner = showH5(productID: productID, session: session, sku: sku, count: count)
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        switch kind {
        case "webview":
            return URL(string: "\(scheme)://webview?url=\(encoded)")
        case "show":
            var c = URLComponents()
            c.scheme = scheme
            c.host = "life_show"
            c.path = "/detail"
            c.queryItems = [URLQueryItem(name: "product_id", value: productID),
                            URLQueryItem(name: "session_time", value: session),
                            URLQueryItem(name: "count", value: String(count))]
            return c.url
        default:
            return URL(string: inner)      // Universal Link，最稳
        }
    }

    /// 依次尝试候选，直到有一个能打开（iOS 会在 App 未安装时回落到浏览器）
    static func candidates(productID: String, session: String, sku: String, count: Int)
        -> [(String, URL)] {
        var out: [(String, URL)] = []
        for app in ["douyin_lite", "douyin"] {
            for kind in ["universal", "webview", "show"] {
                if let u = build(kind: kind, productID: productID, session: session,
                                 sku: sku, count: count, app: app) {
                    out.append(("\(app)/\(kind)", u))
                }
            }
        }
        return out
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        UIApplication.shared.open(url, options: [:]) { ok in
            print("open \(url.absoluteString.prefix(80)) → \(ok)")
        }
        return true
    }
}
