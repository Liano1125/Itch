import SwiftUI
import UniformTypeIdentifiers

struct SparkSyncView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @StateObject private var spark = SparkSyncStore.shared
    @State private var showingFolderPicker = false

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
                    ForEach(spark.summaries) { game in
                        gameCard(game)
                    }
                } else if !spark.isScanning {
                    ContentUnavailableView(
                        "尚未读取 Spark 数据",
                        systemImage: "folder.badge.questionmark",
                        description: Text("选择 Spark 应用的本地数据文件夹（包含 saves 与 backups），itchPocket 会自动扫描正式存档、临时存档和备份。")
                    )
                    .padding(.top, 12)
                }
                if !spark.unmatchedGameNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("尚未匹配到游戏库的存档")
                            .font(.headline)
                        Text("请确认 Spark 游戏文件夹名称与 itchPocket 游戏名称一致。暂不自动关联，避免匹配错误。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(spark.unmatchedGameNames, id: \.self) { name in
                            Label(name, systemImage: "questionmark.folder")
                                .font(.subheadline)
                                .padding(.vertical, 3)
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
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await spark.selectFolder(url, library: library) }
            case .failure(let error):
                spark.errorMessage = error.localizedDescription
            }
        }
        .task {
            if spark.summaries.isEmpty && spark.folderName != nil {
                await spark.rescan(library: library)
            }
        }
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 43, height: 43)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spark 文件夹")
                        .font(.headline)
                    Text(spark.folderName ?? "尚未选择文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if spark.isScanning {
                    ProgressView()
                }
            }

            if let lastSync = spark.lastSyncAt {
                HStack {
                    Text("上次扫描")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastSync.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute()))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack(spacing: 10) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label(spark.folderName == nil ? "选择 Spark 本地文件夹" : "更换文件夹", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button {
                    Task { await spark.rescan(library: library) }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(spark.isScanning || spark.folderName == nil)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("已识别游戏")
                    .font(.headline)
                Text("\(spark.summaries.count) 款 Spark 游戏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("只读同步")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.green.opacity(0.10), in: Capsule())
        }
    }

    private func gameCard(_ game: SparkGameSummary) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(game.gameName)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 8) {
                metric(title: "累计运行时长", value: Self.duration(game.runtimeSeconds), symbol: "clock")
                metric(title: "Ren'Py 版本", value: game.renpyVersion ?? "未读取", symbol: "cpu")
            }

            Divider()

            infoRow("最近存档", dateText(game.lastSaveAt))
            infoRow("最近备份", dateText(game.lastBackupAt))
            infoRow("有效存档数", game.saveCount == 0 ? "未发现" : "\(game.saveCount) 个")
            infoRow("上次启动", "Spark 未提供独立启动记录")
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func metric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .multilineTextAlignment(.trailing)
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
            Label("数据安全说明", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("itchPocket 只读取 Spark 本地数据目录中的 Ren'Py 存档元数据，不会上传、修改或删除存档内容。扫描 saves/renpy/saves、saves/staging/saves 和 backups。游玩时长取有效存档记录中的最高运行时长，历史备份用于补充记录。备份时间、存档时间与真实启动时间分开显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }
}
