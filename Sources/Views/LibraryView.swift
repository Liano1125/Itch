import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var auth: ItchAuthService

    @State private var games: [ItchOwnedGame] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let api = ItchAPI()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var filteredGames: [ItchOwnedGame] {
        guard !searchText.isEmpty else {
            return games
        }

        return games.filter { game in
            let titleMatches = game.title.localizedCaseInsensitiveContains(
                searchText
            )

            let developerMatches = (
                game.user?.displayName ?? game.user?.username ?? ""
            ).localizedCaseInsensitiveContains(searchText)

            return titleMatches || developerMatches
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signedOutView
                } else if isLoading && games.isEmpty {
                    loadingView
                } else if let errorMessage, games.isEmpty {
                    errorView(errorMessage)
                } else if games.isEmpty {
                    emptyView
                } else {
                    gameGrid
                }
            }
            .navigationTitle("游戏库")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                prompt: "搜索游戏或开发者"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await loadGames(force: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || !auth.isSignedIn)
                    .accessibilityLabel("刷新游戏库")
                }
            }
            .task {
                if auth.isSignedIn && !hasLoaded {
                    await loadGames()
                }
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn {
                    Task {
                        await loadGames(force: true)
                    }
                } else {
                    games = []
                    searchText = ""
                    errorMessage = nil
                    hasLoaded = false
                }
            }
        }
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的收藏")
                            .font(.title2.bold())

                        Text("你拥有的 itch.io 游戏")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(games.count) 款游戏")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if filteredGames.isEmpty {
                    ContentUnavailableView(
                        "没有找到游戏",
                        systemImage: "magnifyingglass",
                        description: Text("试试其他游戏名称或开发者")
                    )
                    .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredGames) { game in
                            gameCard(game)
                        }
                    }
                }

                if isLoading {
                    ProgressView("正在同步游戏库…")
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .refreshable {
            await loadGames(force: true)
        }
    }

    // MARK: - Game Card

    private func gameCard(_ game: ItchOwnedGame) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Group {
                if let coverURL = game.coverUrl {
                    AsyncImage(url: coverURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()

                        case .failure:
                            coverPlaceholder

                        case .empty:
                            ZStack {
                                RoundedRectangle(cornerRadius: 13)
                                    .fill(.quaternary)

                                ProgressView()
                            }

                        @unknown default:
                            coverPlaceholder
                        }
                    }
                } else {
                    coverPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.26, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 13))

            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(
                game.user?.displayName
                ?? game.user?.username
                ?? "未知开发者"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let url = game.url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("查看游戏")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(.quaternary)

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - States

    private var signedOutView: some View {
        ContentUnavailableView(
            "尚未登录",
            systemImage: "person.crop.circle",
            description: Text("登录 itch.io 后即可同步你的游戏库")
        )
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("正在读取你的游戏库…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "游戏库还是空的",
            systemImage: "books.vertical",
            description: Text("目前没有读取到已拥有的游戏。可以下拉刷新重试。"
            )
        )
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("读取失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重新加载") {
                Task {
                    await loadGames(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Load Games

    @MainActor
    private func loadGames(force: Bool = false) async {
        guard auth.isSignedIn else {
            return
        }

        guard !isLoading else {
            return
        }

        if hasLoaded && !force {
            return
        }

        guard let token = KeychainStore.read("access_token") else {
            errorMessage = "没有找到登录凭据，请重新登录。"
            hasLoaded = true
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let result = try await api.fetchOwnedGames(
                token: token
            )

            // 如果请求过程中用户已经退出登录，不再更新页面
            guard auth.isSignedIn else {
                return
            }

            games = result
            hasLoaded = true

        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }
}
