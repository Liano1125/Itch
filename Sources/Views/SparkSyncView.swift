import SwiftUI

struct SparkSyncView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @StateObject private var spark = SparkSyncStore.shared

    private let accent = Color(red: 0.94, green: 0.31, blue: 0.34)

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
                        description: Text("先用快捷指令将 Spark/saves/renpy/saves 中的存档复制到 itchPocket/Allsaves，再点击扫描。")
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
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
                }
                privacyNote
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Spark 游玩记录")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await spark.rescan(library: library)
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
                    Text("自动同步目录").font(.headline)
                    Text("无需手动授权，应用直接读取自身文件夹")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if spark.isScanning { ProgressView() }
            }

            folderPathRow(title: "正式存档", path: "itchPocket/Allsaves", detail: "对应 Spark/saves/renpy/saves")

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
                Label(spark.isScanning ? "正在扫描…" : "立即扫描存档", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(spark.isScanning)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private func folderPathRow(title: String, path: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(path).font(.caption.monospaced()).foregroundStyle(.primary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .padding(11)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("已识别游戏").font(.headline)
                Text("\(spark.summaries.count) 款 Spark 游戏").font(.caption).foregroundStyle(.secondary)
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
            infoRow("有效存档槽位", game.saveCount == 0 ? "未发现" : "\(game.saveCount) 个")
            if game.duplicateSaveCount > 0 {
                infoRow("重复存档副本", "\(game.duplicateSaveCount) 份（已去重）")
            }
            infoRow("存档来源", game.saveSources.isEmpty ? "备份记录" : game.saveSources.joined(separator: "、"))
        }
        .padding(15)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
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
        if hours > 0 { return "\(hours)小时\(minutes)分钟" }
        return "\(minutes)分钟"
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("同步方式与数据安全", systemImage: "lock.shield").font(.subheadline.weight(.semibold))
            Text("请在「文件」App 的「我的 iPhone」中打开 itchPocket 文件夹，将 Spark/saves/renpy/saves 中的内容复制到 Allsaves。建议快捷指令采用复制而非移动，并保留每款游戏的原有文件夹层级。itchPocket 只读取 Allsaves，不会上传、修改或删除源文件。游玩时长取有效存档记录中的最高运行时长。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
    }
}
