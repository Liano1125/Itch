import SwiftUI

struct GameUpdateMonitorView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @EnvironmentObject private var monitor: GameUpdateMonitorStore
    @EnvironmentObject private var calendarStore: GameCalendarStore
    @State private var isChecking = false

    var body: some View {
        List {
            Section {
                Text("开启后，itchPocket 会检查游戏页面的 ETag / Last-Modified 响应信息。首次检查只建立基准；之后检测到变化时发送通知。页面没有提供这些信息时，可能无法识别更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                        await monitor.checkAll(calendarStore: calendarStore)
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
