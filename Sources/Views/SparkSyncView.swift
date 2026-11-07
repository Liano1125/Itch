import SwiftUI

struct SparkSyncView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @StateObject private var spark = SparkSyncStore.shared
    @State private var pickerTarget: PickerTarget?

    private let accent = Color(red: 0.94, green: 0.31, blue: 0.34)

    private enum PickerTarget: String, Identifiable {
        case saves
        case backups
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                folderCard
                if let error = spark.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                if !spark.summaries.isEmpty {
                    summaryHeader
                    ForEach(spark.summaries) { game in gameCard(game) }
                } else if !spark.isScanning {
                    ContentUnavailableView(
                        "尚未读取存档数据",
                        systemImage: "folder.badge.questionmark",
                        description: Text("分别选择「itchPocket-allsaves」和「itchPocket-backups」文件夹，应用会读取正式存档与备份。")
                    )
                    .padding(.top, 12)
                }
                if !spark.unmatchedGameNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("尚未匹配到游戏库的存档").font(.headline)
                        Text("请确认存档文件夹名称与 itchPocket 游戏名称一致。暂不自动关联，避免匹配错误。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(spark.unmatchedGameNames, id: \.self) { name in
                            Label(name, systemImage: "questionmark.folder")
                                .font(.subheadline).padding(.vertical, 3)
                        }
                    }
                    .padding(15)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                }
                privacyNote
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Spark 游玩记录")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTarget) { target in
            SparkFolderPicker(
                onPick: { url in
                    pickerTarget = nil
                    Task {
                        if target == .saves {
                            await spark.selectSaveFolder(url, library: library)
                        } else {
                            await spark.selectBackupFolder(url, library: library)
                        }
                    }
                },
                onCancel: { pickerTarget = nil }
            )
            .ignoresSafeArea()
        }
        .task {
            if spark.summaries.isEmpty && (spark.saveFolderName != nil || spark.backupFolderName != nil) {
                await spark.rescan(library: library)
            }
        }
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "folder.fill")
                    .font(.title2).foregroundStyle(accent)
                    .frame(width: 43, height: 43)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("存档目录").font(.headline)
                    Text("分别授权两个快捷指令目标文件夹")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if spark.isScanning { ProgressView() }
            }

            folderRow(title: "正式存档", folderName: spark.saveFolderName, expected: "itchPocket-allsaves") {
                pickerTarget = .saves
            }
            folderRow(title: "历史备份", folderName: spark.backupFolderName, expected: "itchPocket-backups") {
                pickerTarget = .backups
            }

            if let lastSync = spark.lastSyncAt {
                HStack {
                    Text("上次扫描").foregroundStyle(.secondary)
                    Spacer()
                    Text(lastSync.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute()))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Button {
                Task { await spark.rescan(library: library) }
            } label: {
                Label("重新扫描两个目录", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(spark.isScanning || (spark.saveFolderName == nil && spark.backupFolderName == nil))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private func folderRow(title: String, folderName: String?, expected: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(folderName ?? "尚未选择 · 请选择「\\(expected)」")
                    .font(.caption).foregroundStyle(folderName == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer()
            Button(folderName == nil ? "选择" : "更换", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(11)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("已识别游戏").font(.headline)
                Text("\\(spark.summaries.count) 款 Spark 游戏").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("只读扫描").font(.caption.weight(.semibold))
                .foregroundStyle(.green).padding(.horizontal, 10).padding(.vertical, 6)
                .background(.green.opacity(0.10), in: Capsule())
        }
    }

    private func gameCard(_ game: SparkGameSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(game.gameName).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                metric(title: "累计运行时长", value: Self.duration(game.runtimeSeconds), symbol: "clock")
                metric(title: "Ren'Py 版本", value: game.renpyVersion ?? "未读取", symbol: "cpu")
            }
            Divider()
            infoRow("最近存档", dateText(game.lastSaveAt))
            infoRow("最近备份", dateText(game.lastBackupAt))
            infoRow("有效存档槽位", game.saveCount == 0 ? "未发现" : "\\(game.saveCount) 个")
            if game.duplicateSaveCount > 0 {
                infoRow("重复存档副本", "\\(game.duplicateSaveCount) 份（已去重）")
            }
            infoRow("存档来源", game.saveSources.isEmpty ? "备份记录" : game.saveSources.joined(separator: "、"))
            infoRow("上次启动", "Spark 未提供独立启动记录")
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func metric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "暂无记录" }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute())
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "暂无记录" }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\\(hours)小时\\(minutes)分钟" }
        return "\\(minutes)分钟"
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("数据安全说明", systemImage: "lock.shield").font(.subheadline.weight(.semibold))
            Text("itchPocket 只读取你通过快捷指令复制的两个目录：itchPocket-allsaves 中的 Ren'Py 正式存档，以及 itchPocket-backups 中的历史备份。不会上传、修改或删除源文件。游玩时长取有效存档记录中的最高运行时长；备份用于补充历史存档时间与 Ren'Py 版本。真实启动时间仍无法从存档中可靠推断。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }
}
