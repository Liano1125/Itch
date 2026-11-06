import SwiftUI

struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            ContentPlaceholder(
                symbol: "arrow.down.circle",
                title: "还没有下载任务",
                message: "从游戏详情页下载 ZIP 或其他普通文件，任务会显示在这里。"
            )
            .padding()
            .navigationTitle("下载")
        }
    }
}
