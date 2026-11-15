import SwiftUI
import UIKit

struct MonitorView: View {
    @EnvironmentObject var store: Store
    @State private var editing: WatchTask?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button(store.isRunning ? "停止监控" : "开始监控") {
                            if store.isRunning { store.stopAll() } else { store.startAll() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(store.isRunning ? .red : .green)

                        Spacer()
                        Text(store.isRunning ? "监控运行中" : "监控已停止")
                            .font(.footnote)
                            .foregroundStyle(store.isRunning ? .green : .secondary)
                    }
                }

                Section("当前监控任务 \(store.tasks.count)") {
                    if store.tasks.isEmpty {
                        Text("暂无监控任务：去「导入」贴 cURL，或手动加一条")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.tasks) { task in
                        Button {
                            editing = task
                        } label: {
                            TaskRow(task: task)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(task)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }

                Section("实时日志") {
                    if store.logs.isEmpty {
                        Text("[暂无]").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.logs.suffix(60).reversed()) { line in
                        Text(line.line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(for: line.level))
                    }
                }
            }
            .navigationTitle("监控中心")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        let lines = store.logs.suffix(200).map { $0.line }
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                        store.addLog(.info, "诊断日志已复制到剪贴板（\(lines.count) 行）")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        var t = WatchTask(productID: "")
                        t.enabled = false
                        editing = t
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { task in
                TaskEditView(task: task,
                             isNew: store.tasks.first(where: { $0.id == task.id }) == nil)
            }
        }
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .hit: return .green
        case .err: return .red
        case .info: return .primary
        case .dbg: return .secondary
        }
    }
}

struct TaskRow: View {
    let task: WatchTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(task.showName.isEmpty ? task.productID : task.showName)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Spacer()
                Text(task.enabled ? "启用" : "停用")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(task.enabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Text(task.engine == "web" ? "网页" : "直连")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
                Text(task.productID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !task.sessionTime.isEmpty || !task.tierHint.isEmpty {
                Text([task.sessionTime, task.tierHint].filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("阈值\(task.threshold) · 间隔\(String(format: "%.1f", task.interval))s"
                 + (task.skuName.isEmpty ? "" : " · \(task.skuName)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TaskEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var task: WatchTask
    @State private var priceText: String = ""
    var isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("演出") {
                    TextField("商品ID（16 位数字）", text: $task.productID)
                        .keyboardType(.numberPad)
                    TextField("演出名称（可留空，引擎会补）", text: $task.showName)
                    TextField("场次（2026-11-27 19:30）", text: $task.session)
                    if !task.sessionTime.isEmpty {
                        LabeledContent("引擎识别到的场次", value: task.sessionTime)
                    }
                    if !task.tierHint.isEmpty {
                        LabeledContent("引擎识别到的票价", value: task.tierHint)
                    }
                }

                Section("票档") {
                    TextField("票档名（看台 780，留空=整场监控）", text: $task.skuName)
                    TextField("票价（可选）", text: $priceText)
                        .keyboardType(.decimalPad)
                    Stepper("购票人数 \(task.count)", value: $task.count, in: 1...6)
                }

                Section("策略") {
                    Stepper("阈值 \(task.threshold) 张", value: $task.threshold, in: 1...99)
                    HStack {
                        Text("间隔（秒）")
                        Spacer()
                        TextField("1.5", value: $task.interval, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("全局监控（整场票档）", isOn: $task.globalWatch)
                    Toggle("命中后自动打开抖音", isOn: $task.autoOpen)
                    Toggle("启用", isOn: $task.enabled)
                }

                Section("引擎") {
                    Picker("数据来源", selection: $task.engine) {
                        Text("网页引擎（自动签名，推荐）").tag("web")
                        Text("直连接口（需 Cookie）").tag("http")
                    }
                    .pickerStyle(.inline)
                    Text("网页引擎 = 用 WKWebView 打开落地页，由页面自己带上 msToken/a_bogus 去请求，App 只截取响应。不需要抓包。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("落地页 URL（留空自动生成）", text: $task.landingURL)
                        .font(.system(.caption2, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("深链") {
                    Picker("方式", selection: $task.linkKind) {
                        Text("Universal Link").tag("universal")
                        Text("webview").tag("webview")
                        Text("life_show").tag("show")
                    }
                }
            }
            .navigationTitle(isNew ? "新增任务" : "编辑任务")
            .onAppear {
                priceText = task.price > 0 ? String(format: "%g", task.price) : ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        task.price = Double(priceText.trimmingCharacters(in: .whitespaces)) ?? 0
                        if isNew { store.add(task) } else { store.update(task) }
                        dismiss()
                    }
                    .disabled(task.productID.count < 10)
                }
            }
        }
    }
}
