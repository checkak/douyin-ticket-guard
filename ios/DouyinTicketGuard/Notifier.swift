import Foundation
import UIKit
import UserNotifications

/// 通知通道：本地通知（带声音）+ Bark 推送 + 深链拉起抖音。
/// 对齐视频 1:18：通知卡标题「发现库存」，正文「【11.28】演出｜看台780 有票168张（阈值1）」。
final class Notifier {
    static let shared = Notifier()

    private init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("通知授权失败: \(error.localizedDescription)")
            }
            _ = granted
        }
    }

    /// 本地通知（App 在前台/后台都能响，后台靠 BGTask 才有时机）
    func local(title: String, body: String, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .defaultCritical : nil
        content.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1,
                                                                                   repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    /// Bark 推送（跨设备/后台也能响的关键）
    func bark(deviceKey: String, title: String, body: String, url: String?, completion: @escaping (Bool) -> Void) {
        guard !deviceKey.isEmpty,
              let endpoint = URL(string: "https://api.day.app/\(deviceKey)") else {
            completion(false)
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 6
        var payload: [String: Any] = [
            "title": title,
            "body": body,
            "group": "抢票监控",
            "sound": "alarm",
            "level": "timeSensitive",
            "autoCopy": "1",
        ]
        if let url { payload["url"] = url }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200 && err == nil
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 铃响：即使静音也尽量出声（配合 critical alert 需要 entitlement，这里退化为通知声 + 振动）
    func ring() {
        DispatchQueue.main.async {
            let gen = UINotificationFeedbackGenerator()
            gen.notificationOccurred(.success)
            if let url = URL(string: "system://alarm") {
                _ = url
            }
        }
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // 前台也展示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // 点通知 → 打开深链
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["deeplink"] as? String,
           let url = URL(string: link) {
            DeepLink.open(url)
        }
        completionHandler()
    }
}
