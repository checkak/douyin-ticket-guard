import Foundation

// MARK: - 票档

struct Sku: Identifiable, Hashable {
    var id: String
    var name: String
    var priceCents: Double      // 接口常见单位：分
    var stock: Int

    var priceYuan: Double { priceCents >= 1000 ? priceCents / 100 : priceCents }

    var label: String {
        let p = priceYuan.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", priceYuan)
            : String(format: "%.2f", priceYuan)
        return "\(name)  ¥\(p)  剩余\(stock)张"
    }
}

// MARK: - 监控任务

struct WatchTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var productID: String
    var showName: String = ""
    var session: String = ""            // 2026-11-27
    var skuName: String = ""            // 看台 780
    var price: Double = 0
    var count: Int = 1                  // 购票人数
    var threshold: Int = 1              // 阈值
    var interval: Double = 1.5          // 轮询间隔（秒）
    var autoOpen: Bool = true           // 命中后自动打开抖音
    var globalWatch: Bool = false       // 全局监控：整场所有票档都盯
    var scheduleAt: String = ""         // 定时 HH:mm
    var enabled: Bool = false
    var linkKind: String = "universal"  // universal | webview | show
    var engine: String = "web"          // web = WKWebView 自动签名（推荐）| http = 直连（需 Cookie）
    var landingURL: String = ""         // 短链展开后的落地页
    var sessionTime: String = ""        // 从响应里挖到的场次（展示用）
    var tierHint: String = ""           // 响应里挖到的票档摘要

    var title: String {
        var parts: [String] = []
        parts.append(showName.isEmpty ? productID : showName)
        if !session.isEmpty { parts.append(session) }
        if !skuName.isEmpty { parts.append(skuName) }
        return parts.joined(separator: " | ")
    }

    enum CodingKeys: String, CodingKey {
        case id, productID, showName, session, skuName, price, count, threshold, interval
        case autoOpen, globalWatch, scheduleAt, enabled, linkKind, engine, landingURL
        case sessionTime, tierHint
    }

    /// 手写解码：老版本存下来的任务缺字段也能读，且新字段自动补默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        productID = (try? c.decodeIfPresent(String.self, forKey: .productID)) ?? ""
        showName = (try? c.decodeIfPresent(String.self, forKey: .showName)) ?? ""
        session = (try? c.decodeIfPresent(String.self, forKey: .session)) ?? ""
        skuName = (try? c.decodeIfPresent(String.self, forKey: .skuName)) ?? ""
        price = (try? c.decodeIfPresent(Double.self, forKey: .price)) ?? 0
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 1
        threshold = (try? c.decodeIfPresent(Int.self, forKey: .threshold)) ?? 1
        interval = (try? c.decodeIfPresent(Double.self, forKey: .interval)) ?? 1.5
        autoOpen = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpen)) ?? true
        globalWatch = (try? c.decodeIfPresent(Bool.self, forKey: .globalWatch)) ?? false
        scheduleAt = (try? c.decodeIfPresent(String.self, forKey: .scheduleAt)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        linkKind = (try? c.decodeIfPresent(String.self, forKey: .linkKind)) ?? "universal"
        let e = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? ""
        engine = e.isEmpty ? "web" : e          // 老任务一律升级到网页引擎
        landingURL = (try? c.decodeIfPresent(String.self, forKey: .landingURL)) ?? ""
        sessionTime = (try? c.decodeIfPresent(String.self, forKey: .sessionTime)) ?? ""
        tierHint = (try? c.decodeIfPresent(String.self, forKey: .tierHint)) ?? ""
    }
}

// MARK: - 日志

struct LogLine: Identifiable {
    enum Level: String {
        case info = "INFO"
        case hit = "HIT"
        case err = "ERR"
        case dbg = "DEBUG"
    }
    let id = UUID()
    let at: Date
    let level: Level
    let text: String

    var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: at)
    }

    var line: String { "[\(stamp)] \(level.rawValue) \(text)" }
}

// MARK: - 命中事件

struct HitEvent {
    let task: WatchTask
    let sku: Sku
    let link: URL?

    var message: String {
        // 【11-27】演出名 | 看台780 有票168张（阈值1）通知打开抖音
        var prefix = ""
        if task.session.count >= 10 {
            let idx = task.session.index(task.session.startIndex, offsetBy: 5)
            let end = task.session.index(task.session.startIndex, offsetBy: 10)
            prefix = "【\(task.session[idx..<end])】"
        }
        return "\(prefix)\(task.showName)｜\(sku.name) 有票\(sku.stock)张（阈值\(task.threshold)）通知打开抖音"
    }
}
