import Foundation
import UIKit
import BackgroundTasks

/// 全局状态 + 监控引擎。
/// 视频 1:08–1:17 那个「监控中心」就是它：任务、阈值、自动下单开关（这里保留字段）、
/// 任务延迟、全局监控、定时、实时日志。
@MainActor
final class Store: ObservableObject {

    // MARK: 持久化
    @Published var tasks: [WatchTask] = [] { didSet { save() } }
    @Published var logs: [LogLine] = []
    @Published var cookies: [String: String] = [:] { didSet { save() } }
    @Published var headers: [String: String] = [:] { didSet { save() } }
    @Published var barkKey: String = "" { didSet { save() } }
    @Published var isRunning: Bool = false

    private var loops: [UUID: Task<Void, Never>] = [:]
    private var webEngines: [UUID: WebTicketEngine] = [:]
    private var lastStock: [UUID: [String: Int]] = [:]     // 上一轮各票档库存
    private var lastLogSig: [UUID: String] = [:]           // 上一轮库存文本，用于日志去噪
    private var lastFire: [String: Date] = [:]             // "taskid:sku" → 上次触发
    private var inBackground = false

    private let refireCooldown: TimeInterval = 20
    private static let storeKey = "dtg.state.v1"
    private static let bgTaskID = "com.local.dtguard.refresh"

    init() {
        load()
        Notifier.shared.requestAuthorization()
        registerBackgroundTask()
        addLog(.info, "App 就绪：\(tasks.count) 个任务，Cookie \(cookies.count) 个")
    }

    // MARK: - 日志
    func addLog(_ level: LogLine.Level, _ text: String) {
        let line = LogLine(at: Date(), level: level, text: text)
        logs.append(line)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    // MARK: - 任务管理
    func add(_ task: WatchTask) {
        // 同一商品只保留一条任务，避免 web/http 两套引擎同时跑同一个演出
        if let i = tasks.firstIndex(where: { $0.productID == task.productID && !task.productID.isEmpty }) {
            stop(tasks[i])
            var merged = task
            merged.id = tasks[i].id
            if merged.showName.isEmpty { merged.showName = tasks[i].showName }
            if merged.session.isEmpty { merged.session = tasks[i].session }
            if merged.sessionTime.isEmpty { merged.sessionTime = tasks[i].sessionTime }
            if merged.tierHint.isEmpty { merged.tierHint = tasks[i].tierHint }
            if merged.landingURL.isEmpty { merged.landingURL = tasks[i].landingURL }
            tasks[i] = merged
            addLog(.info, "已更新监控：\(merged.title)  引擎=\(merged.engine)")
            if merged.enabled, isRunning { start(merged) }
            return
        }
        tasks.append(task)
        addLog(.info, "已加入监控：\(task.title)  阈值 \(task.threshold)  引擎=\(task.engine)")
    }

    func remove(_ task: WatchTask) {
        stop(task)
        tasks.removeAll { $0.id == task.id }
    }

    func update(_ task: WatchTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
        if task.enabled { start(task) } else { stop(task) }
    }

    // MARK: - 引擎
    func engineEnterForeground() {
        inBackground = false
        guard isRunning else { return }
        for t in tasks where t.enabled { start(t) }
    }

    func engineEnterBackground() {
        inBackground = true
        // 后台无法持续轮询：停掉前台高频循环，交给 BGAppRefresh + Bark
        for (id, loop) in loops {
            loop.cancel()
            loops[id] = nil
        }
        for (id, engine) in webEngines {
            engine.stop()
            webEngines[id] = nil
        }
        addLog(.info, "进入后台：暂停高频轮询，改由系统后台刷新（15 分钟粒度）+ Bark 兜底")
        scheduleBackgroundRefresh()
    }

    func startAll() {
        isRunning = true
        for t in tasks where t.enabled {
            addLog(.info, "启动 \(t.productID) 引擎=\(t.engine) 间隔=\(t.interval)s")
            start(t)
        }
        addLog(.info, "✅ 监听并触发监控已启动（\(tasks.filter { $0.enabled }.count) 个任务）")
    }

    func stopAll() {
        isRunning = false
        for (id, loop) in loops { loop.cancel(); loops[id] = nil }
        for (id, engine) in webEngines { engine.stop(); webEngines[id] = nil }
        addLog(.info, "监控已停止")
    }

    func start(_ task: WatchTask) {
        loops[task.id]?.cancel()
        loops[task.id] = nil
        guard isRunning, task.enabled, !inBackground else { return }
        if task.engine == "web" {
            startWeb(task)
            return
        }
        let client = ApiClient(cookies: cookies, headers: headers)
        loops[task.id] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loop(task: task, client: client)
        }
    }

    func stop(_ task: WatchTask) {
        loops[task.id]?.cancel()
        loops[task.id] = nil
        webEngines[task.id]?.stop()
        webEngines[task.id] = nil
    }

    // MARK: - 网页引擎（WKWebView，页面自己签名）

    private func startWeb(_ task: WatchTask) {
        webEngines[task.id]?.stop()
        let engine = WebTicketEngine()
        webEngines[task.id] = engine

        engine.onLog = { [weak self] level, msg in
            Task { @MainActor in
                let lv: LogLine.Level = level == "ERR" ? .err : (level == "WARN" ? .info : .dbg)
                self?.addLog(lv, "\(task.productID): \(msg)")
            }
        }
        engine.onStatus = { [weak self] status in
            Task { @MainActor in self?.addLog(.dbg, "\(task.productID) 引擎状态: \(status)") }
        }
        engine.onMeta = { [weak self] meta in
            Task { @MainActor in self?.applyMeta(meta, taskID: task.id) }
        }
        engine.onSkus = { [weak self] skus in
            Task { @MainActor in
                guard let self, let t = self.tasks.first(where: { $0.id == task.id }) else { return }
                await self.evaluate(task: t, skus: skus)
            }
        }

        let landing = task.landingURL.isEmpty
            ? Store.landingURL(for: task.productID)
            : task.landingURL
        guard let url = URL(string: landing) else {
            addLog(.err, "落地页 URL 无效：\(landing)")
            return
        }
        addLog(.info, "开始轮询（网页引擎）\(task.title)")
        engine.start(landingURL: url, interval: task.interval)
    }

    /// 团购/演出落地页：不依赖抓包也能构造
    static func landingURL(for productID: String) -> String {
        "https://life.scsjsd.com/falcon/poi_mwa/trade_detail"
            + "?app=aweme&source=groupbuy&is_share_page=1&hide_nav_bar=1"
            + "&should_full_screen=1&activity_id=\(productID)"
    }

    private func applyMeta(_ meta: ApiClient.Meta, taskID: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var changed = false
        if !meta.title.isEmpty, tasks[i].showName.isEmpty {
            tasks[i].showName = meta.title
            changed = true
        }
        if !meta.session.isEmpty, tasks[i].sessionTime != meta.session {
            tasks[i].sessionTime = meta.session
            if tasks[i].session.isEmpty { tasks[i].session = meta.session }
            changed = true
        }
        if let minP = meta.priceHints.min(), let maxP = meta.priceHints.max() {
            let hint = minP == maxP ? "¥\(Int(minP))" : "¥\(Int(minP))~¥\(Int(maxP))"
            if tasks[i].tierHint != hint {
                tasks[i].tierHint = hint
                changed = true
            }
        }
        if changed {
            addLog(.info, "已补齐演出信息：\(tasks[i].showName) · \(tasks[i].sessionTime) · \(tasks[i].tierHint)")
        }
    }

    private func loop(task: WatchTask, client: ApiClient) async {
        var failures = 0
        await addLog(.info, "开始轮询 \(task.title) 间隔 \(task.interval)s")

        while !Task.isCancelled {
            let t0 = Date()
            do {
                let skus = try await client.fetchSkus(productID: task.productID)
                await evaluate(task: task, skus: skus)
                failures = 0
            } catch {
                failures += 1
                await addLog(.err, "\(task.title) 拉库存失败(\(failures)): \(error.localizedDescription)")
                if failures >= 3 {
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 20)) * 1_000_000_000)
                }
            }
            let elapsed = Date().timeIntervalSince(t0)
            let jitter = Double.random(in: 0...0.2)
            let sleep = max(0.3, task.interval + jitter - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
    }

    private func evaluate(task: WatchTask, skus: [Sku]) async {
        let prev = lastStock[task.id] ?? [:]
        var hits: [Sku] = []

        let watched: [Sku]
        if task.globalWatch {
            watched = skus
        } else {
            let match = skus.first { $0.name.replacingOccurrences(of: " ", with: "")
                                      .contains(task.skuName.replacingOccurrences(of: " ", with: "")) }
            let byPrice = skus.first { abs($0.priceYuan - task.price) < 0.5 }
            watched = [match ?? byPrice ?? skus[0]]
        }

        for sku in watched {
            guard sku.stock >= task.threshold else { continue }
            let before = prev[sku.name]
            let isFirst = (before == nil)
            let crossed = (before ?? 0) < task.threshold
            if !(isFirst || crossed) { continue }
            let key = "\(task.id):\(sku.name)"
            if let last = lastFire[key], Date().timeIntervalSince(last) < refireCooldown { continue }
            hits.append(sku)
        }

        var snapshot = prev
        for s in skus { snapshot[s.name] = s.stock }
        lastStock[task.id] = snapshot

        if hits.isEmpty {
            let text = watched.map { "\($0.name):\($0.stock)" }.joined(separator: " / ")
            let sig = text.isEmpty ? "空" : text
            if lastLogSig[task.id] != sig {
                lastLogSig[task.id] = sig
                addLog(.dbg, "\(task.title) → \(sig)")
            }
            return
        }

        for sku in hits {
            lastFire["\(task.id):\(sku.name)"] = Date()
            let link = DeepLink.build(kind: task.linkKind, productID: task.productID,
                                      session: task.session, sku: sku.name, count: task.count)
            let event = HitEvent(task: task, sku: sku, link: link)
            addLog(.hit, event.message)
            fire(event)
        }
    }

    private func fire(_ event: HitEvent) {
        Notifier.shared.local(title: "发现库存", body: event.message)
        Notifier.shared.ring()
        Notifier.shared.bark(deviceKey: barkKey, title: "发现库存", body: event.message,
                             url: event.link?.absoluteString) { [weak self] ok in
            Task { @MainActor in
                self?.addLog(ok ? .info : .err, ok ? "Bark 推送成功" : "Bark 推送失败（检查 Key）")
            }
        }
        if event.task.autoOpen, let link = event.link {
            DeepLink.open(link)
            addLog(.info, "唤起抖音：\(link.absoluteString.prefix(90))")
        }
    }

    // MARK: - 后台刷新
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            self.handleBackgroundRefresh(refresh)
        }
    }

    private func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            addLog(.err, "后台刷新注册失败: \(error.localizedDescription)")
        }
    }

    private nonisolated func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        Task { @MainActor in
            let work = Task { await self.backgroundProbe() }
            task.expirationHandler = { work.cancel() }
            await work.value
            task.setTaskCompleted(success: true)
            self.scheduleBackgroundRefresh()
        }
    }

    private func backgroundProbe() async {
        let client = ApiClient(cookies: cookies, headers: headers)
        for t in tasks where t.enabled {
            do {
                let skus = try await client.fetchSkus(productID: t.productID)
                await evaluate(task: t, skus: skus)
            } catch {
                addLog(.dbg, "后台刷新 \(t.productID) 失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 持久化
    private struct Persisted: Codable {
        var tasks: [WatchTask]
        var cookies: [String: String]
        var headers: [String: String]
        var barkKey: String
    }

    private func save() {
        let p = Persisted(tasks: tasks, cookies: cookies, headers: headers, barkKey: barkKey)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        tasks = p.tasks
        cookies = p.cookies
        headers = p.headers
        barkKey = p.barkKey
    }

    // MARK: - 导入
    func importText(_ text: String) -> ImportParser.Result {
        let r = ImportParser.parse(text)
        if !r.cookies.isEmpty {
            cookies.merge(r.cookies) { _, new in new }
            headers.merge(r.headers) { _, new in new }
        }
        addLog(.info, "导入完成：\(r.summary)")
        return r
    }

    func quickAdd(productID: String, name: String, session: String, landing: String = "") {
        var t = WatchTask(productID: productID)
        t.showName = name
        t.session = session
        t.sessionTime = session
        t.landingURL = landing
        t.engine = "web"
        t.enabled = false
        add(t)
    }
}
