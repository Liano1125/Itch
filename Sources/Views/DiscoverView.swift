import SwiftUI

struct DiscoverView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("发现游戏")
                            .font(.largeTitle.bold())
                        Text("探索 itch.io 上的独立游戏")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索游戏或开发者", text: $searchText)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    ContentPlaceholder(
                        symbol: "sparkles",
                        title: "精彩内容即将到来",
                        message: "接入 itch.io 数据后，这里会展示推荐、热门和最新游戏。"
                    )
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
