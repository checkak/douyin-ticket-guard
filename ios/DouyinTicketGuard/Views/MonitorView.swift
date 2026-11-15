import SwiftUI

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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.showName.isEmpty ? task.productID : task.showName)
                    .font(.subheadline.bold())
                Spacer()
                Text(task.enabled ? "启用" : "停用")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(task.enabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
            Text([task.session, task.skuName, "阈值\(task.threshold)",
                  "间隔\(String(format: "%.1f", task.interval))s"].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TaskEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var task: WatchTask
    var isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("演出") {
                    TextField("商品ID（16 位数字）", text: $task.productID)
                        .keyboardType(.numberPad)
                    TextField("演出名称", text: $task.showName)
                    TextField("场次（2026-11-27 19:30）", text: $task.session)
                }
                Section("票档") {
                    TextField("票档名（看台 780）", text: $task.skuName)
                    TextField("票价（可选）", value: $task.price, format: .number)
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
                Section("深链") {
                    Picker("方式", selection: $task.linkKind) {
                        Text("Universal Link").tag("universal")
                        Text("webview").tag("webview")
                        Text("life_show").tag("show")
                    }
                }
            }
            .navigationTitle(isNew ? "新增任务" : "编辑任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if isNew { store.add(task) } else { store.update(task) }
                        dismiss()
                    }
                    .disabled(task.productID.count < 10)
                }
            }
        }
    }
}
