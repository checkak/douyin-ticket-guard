import Foundation

/// 抖音生活服务/演出 票档接口客户端。
/// 视频 0:26 抓到的真实请求：
///   GET https://life5-normal-m-zb.amemv.com/data/v1/life/general/facade/get_show_sku_info
///       ?...&product_id=xxx
///       Cookie: sessionid=...; sid_guard=...; d_ticket=...
///
/// 响应 schema 未公开，这里用「容错遍历」：任何同时含库存键 + 价格键的节点都算一个票档。
struct ApiClient {
    /// 实测到的区域集群（同一条接口在不同集群上都存在，路由决定用哪个）
    static let defaultHosts = [
        "life5-normal-m-zb.amemv.com",
        "life5-normal-m-zjg.amemv.com",
        "life5-normal-m-gl2.amemv.com",
        "life5-normal-m-lf.amemv.com",
    ]

    /// 用户在设置里手动指定的集群（留空则自动轮询）
    static var customHost: String {
        get { UserDefaults.standard.string(forKey: "dtg.apiHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "dtg.apiHost") }
    }

    var hosts: [String] {
        let c = ApiClient.customHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? ApiClient.defaultHosts : [c]
    }

    static let skuPath = "/data/v1/life/general/facade/get_show_sku_info"
    static let productInfoPath = "/aweme/v2/poi/user/trade/product/info/"

    static let userAgent = "com.ss.android.ugc.aweme.lite/3290 (iPhone; iOS 15.1; Scale/3.00) "

    static let baseParams: [String: String] = [
        "in_sp_time": "0",
        "need_personal_recommend": "1",
        "version_code": "32.9.0",
        "js_sdk_version": "3.56.0.8",
        "tma_jssdk_version": "3.56.0.8",
        "app_name": "douyin_lite",
        "app_version": "32.9.0",
        "channel": "App Store",
        "mcc_mnc": "46001",
        "aid": "2329",
        "minor_status": "0",
        "screen_width": "1242",
        "os_api": "18",
        "ac": "4G",
        "os_version": "15.1",
        "package": "com.ss.android.ugc.aweme.lite",
    ]

    static let stockKeys = ["stock", "stock_num", "remain_stock", "remain", "left_stock",
                            "inventory", "stock_count", "surplus", "available_num", "remain_num"]
    static let priceKeys = ["price", "sale_price", "origin_price", "market_price", "discount_price"]
    static let nameKeys = ["sku_name", "name", "title", "ticket_name", "sku_title", "seat_name"]
    static let idKeys = ["sku_id", "id", "spu_id", "product_id"]

    private let cookies: [String: String]
    private let extraHeaders: [String: String]

    init(cookies: [String: String], headers: [String: String] = [:]) {
        self.cookies = cookies
        self.extraHeaders = headers
    }

    /// 拉一次票档快照：按集群顺序试，谁先返回非空 JSON 就用谁
    func fetchSkus(productID: String) async throws -> [Sku] {
        var errors: [String] = []
        for host in hosts {
            do {
                return try await fetchSkus(productID: productID, host: host)
            } catch {
                errors.append("\(host): \(error.localizedDescription)")
            }
        }
        throw ApiError.allHostsFailed(errors.joined(separator: " | "))
    }

    private func fetchSkus(productID: String, host: String) async throws -> [Sku] {
        var comps = URLComponents(string: "https://" + host + ApiClient.skuPath)!
        var items = ApiClient.baseParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "device_id", value: ApiClient.randomDeviceID()))
        items.append(URLQueryItem(name: "cdid", value: UUID().uuidString))
        items.append(URLQueryItem(name: "product_id", value: productID))
        items.append(URLQueryItem(name: "show_id", value: productID))
        // 每次请求换一下时间戳，避免被当成固定机器人节奏
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue(ApiClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://life.douyin.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if !cookies.isEmpty {
            let cookie = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (k, v) in extraHeaders where k.lowercased().hasPrefix("x-") {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ApiError.transport("no http response")
        }
        if data.isEmpty {
            throw ApiError.emptyBody(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        let skus = ApiClient.extractSkus(obj)
        if skus.isEmpty {
            throw ApiError.noSku("响应里没解析出票档，先 dump 一次看 schema")
        }
        return skus
    }

    static func randomDeviceID() -> String {
        (0..<18).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    // MARK: - 从任意响应里挖「演出名 / 场次 / 票价」

    struct Meta {
        var title: String = ""
        var session: String = ""
        var priceHints: [Double] = []
        var rawKeys: [String] = []

        var isEmpty: Bool { title.isEmpty && session.isEmpty && priceHints.isEmpty }
    }

    static func extractMeta(_ node: Any) -> Meta {
        var meta = Meta()
        var titles: [String] = []
        var sessions: [String] = []
        var keys = Set<String>()

        func dateString(_ ts: Double) -> String {
            let t = ts > 1_000_000_000_000 ? ts / 1000 : ts     // 毫秒兼容
            let d = Date(timeIntervalSince1970: t)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.locale = Locale(identifier: "zh_CN")
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            return f.string(from: d)
        }

        func asText(_ v: Any?) -> String? {
            if let s = v as? String, !s.isEmpty {
                if let n = Double(s), n > 1_600_000_000 { return dateString(n) }
                return s
            }
            if let n = v as? Double { return n > 1_600_000_000 ? dateString(n) : nil }
            if let i = v as? Int { return i > 1_600_000_000 ? dateString(Double(i)) : nil }
            if let n = v as? NSNumber { return dateString(n.doubleValue) }
            return nil
        }

        func walk(_ n: Any) {
            if let d = n as? [String: Any] {
                for (k, v) in d {
                    let lk = k.lowercased()
                    if ["title", "product_name", "show_name", "sku_name"].contains(lk),
                       let s = v as? String, s.count >= 4, s.count <= 90 {
                        titles.append(s)
                    }
                    if ["session_time", "show_time", "start_time", "valid_start",
                        "begin_time", "session", "time_desc"].contains(lk),
                       let s = asText(v) {
                        sessions.append(s)
                    }
                    if lk.contains("sku") || lk.contains("stock") || lk.contains("price") {
                        keys.insert(k)
                    }
                }
                for (_, v) in d { walk(v) }
            } else if let a = n as? [Any] {
                for v in a { walk(v) }
            }
        }

        walk(node)
        meta.title = titles.first(where: { $0.contains("演唱会") || $0.contains("巡演") })
            ?? titles.max(by: { $0.count < $1.count }) ?? ""
        meta.session = sessions.first(where: { $0.contains("-") }) ?? sessions.first ?? ""
        meta.priceHints = extractSkus(node).map { $0.priceYuan }
        meta.rawKeys = keys.sorted()
        return meta
    }

    /// 容错遍历 JSON，捞出所有「库存 + 价格」节点
    static func extractSkus(_ node: Any) -> [Sku] {
        var found: [Sku] = []

        func pick(_ dict: [String: Any], _ keys: [String]) -> Any? {
            for k in keys {
                if let v = dict[k], !(v is NSNull) { return v }
            }
            return nil
        }

        func num(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let stockV = pick(dict, stockKeys), let priceV = pick(dict, priceKeys),
                   let stock = num(stockV), let price = num(priceV) {
                    let nameV = pick(dict, nameKeys)
                    let name = (nameV as? String) ?? "sku-\(pick(dict, idKeys).map { "\($0)" } ?? "\(found.count)")"
                    let sid = pick(dict, idKeys).map { "\($0)" } ?? "\(found.count)"
                    found.append(Sku(id: sid, name: name, priceCents: price, stock: Int(stock)))
                }
                for (_, v) in dict { walk(v) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }

        walk(node)

        // 同名同价去重
        var seen = Set<String>()
        return found.filter { sku in
            let key = "\(sku.name)#\(sku.priceYuan)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    enum ApiError: LocalizedError {
        case transport(String)
        case emptyBody(Int)
        case noSku(String)
        case allHostsFailed(String)

        var errorDescription: String? {
            switch self {
            case .transport(let m): return "网络失败: \(m)"
            case .emptyBody(let code):
                return "HTTP \(code) 但响应体为空 —— 缺 web 端签名/Cookie（msToken、a_bogus、sid_guard）"
            case .noSku(let m): return m
            case .allHostsFailed(let m):
                return "所有集群都失败（\(ApiClient.defaultHosts.count) 个）: \(m)"
            }
        }
    }
}
