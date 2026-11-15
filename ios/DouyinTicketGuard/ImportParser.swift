import Foundation

/// cURL / HAR / 订单链接 → cookies + product_id
/// 对应视频 0:26「订单链接解析」页。
enum ImportParser {

    struct Result {
        var cookies: [String: String] = [:]
        var headers: [String: String] = [:]
        var productID: String = ""
        var session: String = ""
        var price: Double = 0
        var kind: String = ""       // curl | har | link | cookie
        var url: String = ""        // 识别到的链接（展开前/后）

        var hasAuth: Bool {
            !["sessionid", "sessionid_ss", "sid_guard"].filter { cookies[$0] != nil }.isEmpty
        }

        var summary: String {
            "\(kind) · cookies \(cookies.count) 个 · 登录态 \(hasAuth ? "有" : "无") · 商品ID \(productID.isEmpty ? "未识别" : productID)"
        }
    }

    static let productRe = try! NSRegularExpression(pattern: "(?:product_id|show_id|spu_id|activity_id)=?(\\d{15,19})")
    static let dateRe = try! NSRegularExpression(pattern: "(20\\d{2}-\\d{2}-\\d{2})")
    static let timeRe = try! NSRegularExpression(pattern: "([01]\\d|2[0-3]):[0-5]\\d")
    static let priceRe = try! NSRegularExpression(pattern: "(?:¥|￥)?\\s*(\\d{2,5}(?:\\.\\d{1,2})?)\\s*元")

    static func parse(_ raw: String) -> Result {
        var r = Result()
        let t = normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        if t.hasPrefix("{"), t.contains("\"log\"") || t.contains("\"entries\"") {
            r.kind = "har"
            parseHAR(t, into: &r)
        } else if t.lowercased().contains("curl") {
            r.kind = "curl"
            parseCurl(t, into: &r)
        } else if let u = firstURL(t), u.host?.contains("douyin") == true {
            r.kind = "link"
            r.url = u.absoluteString
        } else if t.contains("http") {
            r.kind = "link"
            r.url = firstURL(t)?.absoluteString ?? ""
        } else {
            r.kind = "cookie"
            r.cookies.merge(parseCookieString(t)) { a, _ in a }
        }

        fillFreeText(t, into: &r)
        return r
    }

    /// `v.douyin.com/xxx` 这种没写 scheme 的也补成 https
    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = ["v.douyin.com", "www.douyin.com", "douyin.com", "life.douyin.com",
                     "haohuo.jinritemai.com", "life.scsjsd.com"]
        if hosts.contains(where: { t.lowercased().hasPrefix($0) }) {
            return "https://" + t
        }
        return t
    }

    /// 从任意文本里挑出第一个 URL
    static func firstURL(_ text: String) -> URL? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s"'<>，。]+"#) else {
            return nil
        }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        var s = ns.substring(with: m.range)
        while s.hasSuffix(")") || s.hasSuffix("]") || s.hasSuffix(",") || s.hasSuffix("，") {
            s.removeLast()
        }
        return URL(string: s)
    }

    // MARK: cURL
    private static func parseCurl(_ text: String, into r: inout Result) {
        let cleaned = text.replacingOccurrences(of: "\\\r\n", with: " ")
                          .replacingOccurrences(of: "\\\n", with: " ")
        let tokens = tokenize(cleaned)
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            let low = tok.lowercased()
            if (low == "-h" || low == "--header"), i + 1 < tokens.count {
                let h = tokens[i + 1]
                if let sep = h.firstIndex(of: ":") {
                    let k = String(h[..<sep]).trimmingCharacters(in: .whitespaces)
                    let v = String(h[h.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                    if k.lowercased() == "cookie" {
                        r.cookies.merge(parseCookieString(v)) { a, _ in a }
                    } else {
                        r.headers[k] = v
                    }
                }
                i += 2
                continue
            }
            if (low == "-b" || low == "--cookie"), i + 1 < tokens.count {
                r.cookies.merge(parseCookieString(tokens[i + 1])) { a, _ in a }
                i += 2
                continue
            }
            i += 1
        }
    }

    // MARK: HAR
    private static func parseHAR(_ text: String, into r: inout Result) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else { return }

        var best: [String: Any]?
        var bestScore = -1
        for e in entries {
            guard let req = e["request"] as? [String: Any] else { continue }
            let url = req["url"] as? String ?? ""
            var score = 0
            if url.contains("get_show_sku_info") { score += 100 }
            if url.contains("product/info") { score += 100 }
            if url.contains("product_id") { score += 10 }
            let headers = req["headers"] as? [[String: Any]] ?? []
            if headers.contains(where: { ($0["name"] as? String)?.lowercased() == "cookie" }) { score += 5 }
            if score > bestScore { bestScore = score; best = req }
        }
        guard let req = best else { return }
        for h in (req["headers"] as? [[String: Any]] ?? []) {
            guard let name = h["name"] as? String, let value = h["value"] as? String else { continue }
            if name.lowercased() == "cookie" {
                r.cookies.merge(parseCookieString(value)) { a, _ in a }
            } else {
                r.headers[name] = value
            }
        }
    }

    // MARK: 公共
    private static func parseCookieString(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        let parts = raw.replacingOccurrences(of: "\\n", with: " ")
                        .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = String(p[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !k.isEmpty, !v.isEmpty else { continue }
            if ["path", "domain", "expires", "max-age", "samesite"].contains(k.lowercased()) { continue }
            out[k] = v
        }
        return out
    }

    private static func fillFreeText(_ text: String, into r: inout Result) {
        if r.productID.isEmpty, let m = firstMatch(productRe, in: text, group: 1) {
            r.productID = m
        }
        let date = firstMatch(dateRe, in: text, group: 1)
        let time = firstMatch(timeRe, in: text, group: 1)
        if let d = date {
            if let t = time {
                r.session = d + " " + t
            } else {
                r.session = d
            }
        }
        if r.price == 0, let p = firstMatch(priceRe, in: text, group: 1), let v = Double(p) {
            r.price = v
        }
    }

    private static func firstMatch(_ re: NSRegularExpression, in text: String, group: Int) -> String? {
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group else { return nil }
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    /// 简单 shell tokenizer，够处理 cURL 的单双引号
    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == " " || ch == "\n" || ch == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
