import SwiftUI

struct DiscoverView: View {
    @Environment(\.openURL) private var openURL

    @State private var searchText = ""

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("发现游戏")
                            .font(.largeTitle.bold())

                        Text("探索 itch.io 上的独立游戏")
                            .foregroundStyle(.secondary)
                    }

                    searchBar

                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            "搜索 itch.io",
                            systemImage: "magnifyingglass"
                        )
                        .font(.headline)

                        Text("输入游戏名称、开发者或关键词，搜索结果将在 itch.io 官方页面打开。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(action: performSearch) {
                            HStack {
                                Spacer()

                                Image(systemName: "magnifyingglass")
                                Text("搜索游戏")

                                Spacer()
                            }
                            .font(.headline)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedSearchText.isEmpty)
                    }
                    .padding(16)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 20)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("浏览 itch.io")
                            .font(.headline)

                        Link(
                            destination: URL(
                                string: "https://itch.io/games"
                            )!
                        ) {
                            Label(
                                "浏览全部游戏",
                                systemImage: "gamecontroller"
                            )
                        }

                        Link(
                            destination: URL(
                                string: "https://itch.io/games/featured"
                            )!
                        ) {
                            Label(
                                "精选游戏",
                                systemImage: "star"
                            )
                        }

                        Link(
                            destination: URL(
                                string: "https://itch.io/games/price-free"
                            )!
                        ) {
                            Label(
                                "免费游戏",
                                systemImage: "gift"
                            )
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "搜索游戏或开发者",
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                performSearch()
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(15)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 17)
        )
    }

    // MARK: - Search Action

    private func performSearch() {
        guard !trimmedSearchText.isEmpty else {
            return
        }

        var components = URLComponents(
            string: "https://itch.io/search"
        )!

        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: trimmedSearchText
            )
        ]

        guard let url = components.url else {
            return
        }

        openURL(url)
    }
}
