import SwiftUI

struct CacheManagementView: View {
    @State private var summary = AppCacheManager.summary()
    @State private var showingConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("缓存占用") {
                LabeledContent("游戏介绍与更新译文", value: "\(summary.translations) 条")
                LabeledContent("发现与公开合集", value: "\(summary.discoverySnapshots) 份")
                LabeledContent("图片缓存", value: ByteCountFormatter.string(fromByteCount: summary.imageBytes, countStyle: .file))
            }

            Section {
                Button(role: .destructive) {
                    showingConfirmation = true
                } label: {
                    Label("清理可重新生成的缓存", systemImage: "trash")
                }
            } footer: {
                Text("只清理图片、翻译和发现结果缓存。游戏介绍与画廊资料暂时保留，待独立详情缓存迁移完成后再纳入清理。不会删除游戏库、日历事件、开发者关注关系、Spark 游玩记录或登录凭据。")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定清理缓存？", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) {
                Task {
                    do {
                        try await AppCacheManager.clearRebuildableCaches()
                        summary = AppCacheManager.summary()
                        errorMessage = nil
                    } catch {
                        errorMessage = "清理失败：\(error.localizedDescription)"
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后图片、翻译和发现结果会在需要时重新获取；已保存的游戏介绍与画廊资料会保留。")
        }
        .onAppear { summary = AppCacheManager.summary() }
    }
}
