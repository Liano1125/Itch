import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var auth: ItchAuthService

    @State private var collections: [ItchCollection] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let api = ItchAPI()

    private var filteredCollections: [ItchCollection] {
        guard !searchText.isEmpty else {
            return collections
        }

        return collections.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isSignedIn {
                    signedOutView
                } else if isLoading && collections.isEmpty {
                    loadingView
                } else if let errorMessage, collections.isEmpty {
                    errorView(errorMessage)
                } else if collections.isEmpty {
                    emptyView
                } else {
                    collectionList
                }
            }
            .navigationTitle("游戏库")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                prompt: "搜索合集"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await loadCollections(force: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || !auth.isSignedIn)
                    .accessibilityLabel("刷新合集")
                }
            }
            .task {
                if auth.isSignedIn && !hasLoaded {
                    await loadCollections()
                }
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn {
                    Task {
                        await loadCollections(force: true)
                    }
                } else {
                    collections = []
                    searchText = ""
                    errorMessage = nil
                    hasLoaded = false
                }
            }
        }
    }

    // MARK: - Collection List

    private var collectionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的合集")
                        .font(.title2.bold())

                    Text("浏览你在 itch.io 创建或管理的游戏合集")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(collections.count) 个合集")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if filteredCollections.isEmpty {
                    ContentUnavailableView(
                        "没有找到合集",
                        systemImage: "magnifyingglass",
                        description: Text("试试其他合集名称")
                    )
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredCollections) { collection in
                            NavigationLink {
                                CollectionDetailView(
                                    collection: collection
                                )
                            } label: {
                                collectionCard(collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
            await loadCollections(force: true)
        }
    }

    private func collectionCard(
        _ collection: ItchCollection
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(.quaternary)

                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 6) {
                Text(collection.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(collection.gamesCount ?? 0) 款游戏")

                    if collection.isPrivate == true {
                        Text("·")
                        Label("私有", systemImage: "lock.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 19)
        )
    }

    // MARK: - States

    private var signedOutView: some View {
        ContentUnavailableView(
            "尚未登录",
            systemImage: "person.crop.circle",
            description: Text("登录 itch.io 后即可读取你的游戏合集")
        )
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("正在读取你的合集…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "还没有找到合集",
            systemImage: "square.stack.3d.up",
            description: Text("目前没有读取到你创建或管理的 Collection。")
        )
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                "读取合集失败",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button("重新加载") {
                Task {
                    await loadCollections(force: true)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Load Collections

    @MainActor
    private func loadCollections(
        force: Bool = false
    ) async {

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
            let result = try await api.fetchCollections(
                token: token
            )

            guard auth.isSignedIn else {
                return
            }

            collections = result
            hasLoaded = true

        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }
}

// MARK: - Collection Detail

struct CollectionDetailView: View {
    @EnvironmentObject private var auth: ItchAuthService

    let collection: ItchCollection

    @State private var games: [ItchGame] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private let api = ItchAPI()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var filteredGames: [ItchGame] {
        guard !searchText.isEmpty else {
            return games
        }

        return games.filter { game in
            let titleMatches = game.title.localizedCaseInsensitiveContains(
                searchText
            )

            let developerMatches = (
                game.user?.displayName
                ?? game.user?.username
                ?? ""
            ).localizedCaseInsensitiveContains(searchText)

            return titleMatches || developerMatches
        }
    }

    var body: some View {
        Group {
            if isLoading && games.isEmpty {
                loadingView
            } else if let errorMessage, games.isEmpty {
                errorView(errorMessage)
            } else if games.isEmpty {
                emptyView
            } else {
                gameGrid
            }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            prompt: "搜索合集中的游戏"
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
                .disabled(isLoading)
                .accessibilityLabel("刷新游戏")
            }
        }
        .task {
            if !hasLoaded {
                await loadGames()
            }
        }
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(collection.title)
                        .font(.title2.bold())

                    Text("\(games.count) 款游戏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if filteredGames.isEmpty {
                    ContentUnavailableView(
                        "没有找到游戏",
                        systemImage: "magnifyingglass",
                        description: Text("试试其他游戏名称或开发者")
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredGames) { game in
                            ItchGameCard(game: game)
                        }
                    }
                }

                if isLoading {
                    ProgressView("正在加载更多游戏…")
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

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("正在读取合集中的游戏…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "这个合集还没有游戏",
            systemImage: "gamecontroller",
            description: Text("这个 Collection 目前没有可显示的游戏。")
        )
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                "读取游戏失败",
                systemImage: "exclamationmark.triangle"
            )
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
    private func loadGames(
        force: Bool = false
    ) async {

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
            let result = try await api.fetchCollectionGames(
                collectionID: collection.id,
                token: token
            )

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

// MARK: - Game Card

private struct ItchGameCard: View {
    let game: ItchGame

    var body: some View {
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
                .foregroundStyle(.primary)
                .lineLimit(2)

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
}
