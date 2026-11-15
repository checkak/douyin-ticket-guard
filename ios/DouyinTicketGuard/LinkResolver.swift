import Foundation

/// 抖音分享短链展开：`https://v.douyin.com/xxxx/` 是 302 短链，
/// 必须跟到落地页（`life.scsjsd.com/falcon/poi_mwa/trade_detail?...&activity_id=...`）
/// 才能拿到商品ID。对应 Python 版的 `dg.parse.resolve_short_link`。
///
/// 关键实现点：URLSession 默认会自动跟随 302，那样就拿不到中间跳转和 `Location`；
/// 这里用 delegate 关掉自动跳转，逐跳读取，既能记录链路，也能识别 `snssdk1128://`。
enum LinkResolver {

    struct Result {
        var finalURL: URL?
        var productID: String = ""
        var info: String = ""            // 【】里的日期，如 11月27日 → 2026-11-27 由调用方补
        var hops: [String] = []
        var note: String = ""
        var isGroupBuy: Bool = false

        var summary: String {
            var parts: [String] = []
            if !productID.isEmpty { parts.append("商品ID \(productID)") }
            if isGroupBuy { parts.append("团购商品") }
            if !note.isEmpty { parts.append(note) }
            return parts.joined(separator: " · ")
        }
    }

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_1 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 " +
        "Aweme/3290 (iPhone; iOS 15.1; Scale/3.00)"

    private static let idPattern = #"(?:product_id|show_id|spu_id|activity_id)=?(\d{15,19})"#
    private static let bareIdPattern = #"\b(1\d{15,18})\b"#
    private static let schemePattern = #"(?:snssdk1128|douyinlite|douyin|aweme)://[^"'\s<>]+"#

    static func resolve(_ url: URL, maxHops: Int = 8) async -> Result {
        var r = Result(finalURL: url)
        guard url.scheme == "http" || url.scheme == "https" else {
            r.productID = extractID(url.absoluteString)
            r.note = r.productID.isEmpty ? "不是 http 链接" : ""
            return r
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: cfg, delegate: NoRedirect(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var current = url
        for _ in 0..<maxHops {
            var req = URLRequest(url: current)
            req.httpMethod = "GET"
            req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
            req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    r.note = "非 HTTP 响应"
                    break
                }
                r.hops.append("\(http.statusCode) \(current.absoluteString)")

                let loc = http.value(forHTTPHeaderField: "Location")
                if let loc, !loc.isEmpty,
                   let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                    if isAppScheme(next) {
                        r.hops.append("→ 内嵌 scheme \(next.absoluteString.prefix(90))")
                        r.finalURL = next
                        r.productID = extractID(next.absoluteString)
                        break
                    }
                    current = next
                    continue
                }

                // 200：先从 URL 取，再从页面正文捞
                r.finalURL = current
                let body = String(data: data, encoding: .utf8) ?? ""
                if let m = firstMatch(schemePattern, in: body) {
                    r.hops.append("→ 内嵌 scheme \(m.prefix(90))")
                }
                let fromURL = extractID(current.absoluteString)
                r.productID = fromURL.isEmpty ? extractID(body) : fromURL
                if current.absoluteString.contains("source=groupbuy")
                    || body.contains("groupbuy") {
                    r.isGroupBuy = true
                }
                if r.productID.isEmpty {
                    r.note = "落地页里没有商品ID（团购/演出页多为 JS 渲染，需要抓包）"
                }
                break
            } catch {
                r.note = "\(type(of: error)) — \(error.localizedDescription)"
                break
            }
        }
        if r.productID.isEmpty && r.note.isEmpty {
            r.note = "跳转超过 \(maxHops) 层仍未拿到商品ID"
        }
        return r
    }

    // MARK: - 工具

    private static func isAppScheme(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased() else { return false }
        return ["snssdk1128", "douyinlite", "douyin", "aweme"].contains(s)
    }

    static func extractID(_ text: String) -> String {
        if let m = firstMatch(idPattern, in: text) { return m }
        if let m = firstMatch(bareIdPattern, in: text) { return m }
        return ""
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }
}

/// 阻止 URLSession 自动跟随跳转，把每一跳交回给调用方处理
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
