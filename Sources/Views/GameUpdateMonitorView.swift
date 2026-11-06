import SwiftUI

struct GameUpdateMonitorView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @EnvironmentObject private var monitor: GameUpdateMonitorStore
    @EnvironmentObject private var calendarStore: GameCalendarStore
    @State private var isChecking = false
    @State private var isSyncingHistory = false
    @State private var historySyncMessage: String?

    var body: some View {
        List {
            Section {
                Text("开启后，itchPocket 会检查游戏页面的 ETag / Last-Modified 响应信息。首次检查只建立基准；之后检测到变化时发送通知。页面没有提供这些信息时，可能无法识别更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("自动同步状态") {
                HStack(spacing: 10) {
                    if monitor.isSyncingHistoricalDevlogs {
                        ProgressView()
                        Text("正在检查公开 Devlog…")
                    } else {
                        Image(systemName: monitor.lastHistoricalSyncAt == nil ? "clock" : "checkmark.circle")
                            .foregroundStyle(monitor.lastHistoricalSyncAt == nil ? .secondary : .green)
                        Text(monitor.lastHistoricalSyncAt == nil ? "尚未执行同步" : "最近一次同步")
                    }
                    Spacer()
                    if let date = monitor.lastHistoricalSyncAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = monitor.lastHistoricalSyncMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("每次启动 App 时自动检查；后台检查由 iOS 系统择机执行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !monitor.lastHistoricalSyncResults.isEmpty {
                    ForEach(monitor.lastHistoricalSyncResults) { result in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: result.message.hasPrefix("读取失败") || result.message.contains("失败") || result.message.contains("缺少有效") ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(result.message.hasPrefix("读取失败") || result.message.contains("失败") || result.message.contains("缺少有效") ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.gameTitle)
                                    .font(.subheadline)
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            Section("历史版本更新") {
                Text("自动同步已开启：打开 App 时会检查；iOS 也会在系统允许时安排后台刷新（目标间隔约 6 小时，但实际时间由系统决定）。发现新 Devlog 后会自动写入日历和个人游戏库。仅能获取开发者公开发布的 Devlog RSS。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("从每款游戏的 itch.io Devlog RSS 导入已发布的更新日志。日历使用原始发布日期，历史记录不会触发通知；没有公开 Devlog 的游戏可能没有可导入内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    isSyncingHistory = true
                    historySyncMessage = nil
                    Task {
                        historySyncMessage = await monitor.syncHistoricalDevlogs(
                            records: library.records,
                            calendarStore: calendarStore,
                            libraryStore: library
                        )
                        isSyncingHistory = false
                    }
                } label: {
                    HStack {
                        if isSyncingHistory { ProgressView() }
                        Text(isSyncingHistory ? "正在同步历史更新…" : "同步全部游戏的历史更新")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isSyncingHistory || library.records.isEmpty)
                if let historySyncMessage {
                    Text(historySyncMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("个人游戏库") {
                if library.records.isEmpty {
                    ContentUnavailableView("游戏库为空", systemImage: "gamecontroller")
                } else {
                    ForEach(library.records) { record in
                        let watch = monitor.watch(for: record.id)
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(record.title, isOn: Binding(
                                get: { watch?.isEnabled ?? false },
                                set: { monitor.setEnabled($0, for: record) }
                            ))
                            if let watch, watch.isEnabled {
                                Text(watch.lastCheckedAt.map { "上次检查：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未检查")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    isChecking = true
                    Task {
                        await monitor.checkAll(calendarStore: calendarStore, libraryStore: library)
                        isChecking = false
                    }
                } label: {
                    HStack {
                        if isChecking { ProgressView() }
                        Text(isChecking ? "正在检查…" : "立即检查所有已监控游戏")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isChecking || !monitor.watches.values.contains(where: \.isEnabled))
                if let message = monitor.statusMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("游戏更新提醒")
        .navigationBarTitleDisplayMode(.inline)
    }
}
