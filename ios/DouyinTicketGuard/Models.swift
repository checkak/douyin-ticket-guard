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

    var title: String {
        var parts: [String] = []
        parts.append(showName.isEmpty ? productID : showName)
        if !session.isEmpty { parts.append(session) }
        if !skuName.isEmpty { parts.append(skuName) }
        return parts.joined(separator: " | ")
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

    var body: String {
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
