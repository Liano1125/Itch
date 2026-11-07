import SwiftUI
import WebKit

private struct DiscoveryTagRecommendation: Identifiable {
    let id: String
    let name: String
    let url: String
    let gameCount: Int
}

private struct DiscoveryFeed: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let url: URL
    static let curated: [DiscoveryFeed] = [
        DiscoveryFeed(id: "adjacent-renpy", title: "Adult Ren'Py Games", subtitle: "更多成人 Ren'Py 游戏", url: URL(string: "https://itch.io/games/tag-renpy/tag-adult")!),
        DiscoveryFeed(id: "adjacent-3d", title: "Other 3D Adult Games", subtitle: "其他 3D 成人游戏", url: URL(string: "https://itch.io/games/tag-3d/tag-adult")!)
    ]
}

private struct DeveloperRecommendation: Identifiable {
    let name: String
    let records: [LibraryRecord]
    var id: String { name.lowercased() }
}

struct DiscoverView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var showSearchResults = false
    @State private var recommendedGames: [PublicCollectionGame] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationError: String?
    @State private var recommendationReloadToken = UUID()
    @State private var curatedReloadToken = UUID()
    @State private var curatedGames: [String: [PublicCollectionGame]] = Self.loadCuratedCache()
    @State private var isLoadingCurated = false
    @State private var curatedError: String?

    private static let curatedCacheKey = "itchPocket.curatedFeeds.v1"

    private static func loadCuratedCache() -> [String: [PublicCollectionGame]] {
        guard let data = UserDefaults.standard.data(forKey: curatedCacheKey),
              let cached = try? JSONDecoder().decode([String: [PublicCollectionGame]].self, from: data) else {
            return [:]
        }
        return cached
    }

    private func persistCuratedCache() {
        let compact = curatedGames.mapValues { Array($0.prefix(24)) }
        guard let data = try? JSONEncoder().encode(compact) else { return }
        UserDefaults.standard.set(data, forKey: Self.curatedCacheKey)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    searchBar
                    curatedFeedSection
                    personalizedSection
                    developerSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 0) {
                    DiscoveryFeedReader(
                        url: recommendationURL,
                        reloadToken: recommendationReloadToken,
                        onLoad: { games in
                            recommendedGames = games.filter { !library.contains($0.id) }
                            isLoadingRecommendations = false
                            recommendationError = nil
                        },
                        onError: { message in
                            isLoadingRecommendations = false
                            recommendationError = message
                        },
                        onStart: { isLoadingRecommendations = true }
                    )
                    .frame(width: 1, height: 1)
                    CuratedDiscoveryFeedReader(
                        feeds: DiscoveryFeed.curated,
                        reloadToken: curatedReloadToken,
                        onLoad: { feedID, games in
                            let available = games.filter { !library.contains($0.id) }
                            // Never replace a populated feed with an empty page/result.
                            if !available.isEmpty || curatedGames[feedID] == nil {
                                curatedGames[feedID] = available
                                persistCuratedCache()
                            }
                            if !available.isEmpty { curatedError = nil }
                        },
                        onError: { curatedError = $0 },
                        onStart: { isLoadingCurated = true; curatedError = nil },
                        onFinish: { isLoadingCurated = false }
                    )
                    .frame(width: 1, height: 1)
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .navigationDestination(isPresented: $showSearchResults) {
                ItchSearchResultsView(query: submittedQuery)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.36))

                Text("ITCHPOCKET")
                    .font(.caption.weight(.heavy))
                    .tracking(2.2)
                    .foregroundStyle(.secondary)
            }

            Text("发现值得玩的\\n视觉小说游戏")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("搜索游戏或开发者", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(performSearch)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .accessibilityLabel("清空搜索")
            }

            Button(action: performSearch) {
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        trimmedSearchText.isEmpty
                        ? Color.secondary.opacity(0.35)
                        : Color(red: 0.94, green: 0.31, blue: 0.34),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            }
            .disabled(trimmedSearchText.isEmpty)
            .accessibilityLabel("搜索")
        }
        .padding(.leading, 16)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var curatedFeedSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer()
                if isLoadingCurated {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        curatedReloadToken = UUID()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityLabel("刷新作品")
                }
            }
            ForEach(DiscoveryFeed.curated) { feed in curatedFeedRow(feed) }
            if let curatedError, curatedGames.isEmpty, !isLoadingCurated {
                Text("暂时无法加载作品：\\(curatedError)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func curatedFeedRow(_ feed: DiscoveryFeed) -> some View {
        let games = (curatedGames[feed.id] ?? []).filter { !library.contains($0.id) }
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.title).font(.headline)
                    Text(feed.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !games.isEmpty {
                    NavigationLink {
                        ItchSearchResultsView(query: "", customURL: feed.url.absoluteString)
                    } label: {
                        HStack(spacing: 4) { Text("更多"); Image(systemName: "chevron.right") }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            if !games.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(games.prefix(24)) { game in
                            NavigationLink {
                                GameDetailView(game: game)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    CachedRemoteImage(url: game.coverURL, contentMode: .fill) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(uiColor: .tertiarySystemFill))
                                            .overlay { Image(systemName: "gamecontroller.fill").foregroundStyle(.tertiary) }
                                    }
                                    .frame(width: 164, height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(game.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                                        .frame(width: 164, alignment: .leading)
                                    if let developer = game.developer, !developer.isEmpty {
                                        Text(developer).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).frame(width: 164, alignment: .leading)
                                    }
                                }
                                .frame(width: 164, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if isLoadingCurated {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在加载作品…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if let curatedError {
                VStack(alignment: .leading, spacing: 9) {
                    Text(curatedError)
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        ItchSearchResultsView(query: feed.title, customURL: feed.url.absoluteString)
                    } label: {
                        Label("前往 itch.io 确认年龄并浏览", systemImage: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.vertical, 8)
            } else {
                Text("暂时没有可展示的作品")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从这里开始")
                        .font(.title3.bold())
                }

                Spacer()

                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.98, green: 0.48, blue: 0.38))
            }

            NavigationLink {
                ItchSearchResultsView(query: "", customURL: "https://itch.io/games/featured")
            } label: {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.30, green: 0.16, blue: 0.20),
                                    Color(red: 0.13, green: 0.14, blue: 0.20)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Circle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 190, height: 190)
                        .offset(x: 205, y: -42)

                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 150, height: 150)
                        .offset(x: 230, y: 54)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("FEATURED GAMES")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.8)
                            .foregroundStyle(.white.opacity(0.68))

                        Text("独立游戏精选")
                            .font(.title2.bold())
                            .foregroundStyle(.white)

                        HStack(spacing: 7) {
                            Text("浏览 itch.io 编辑精选")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(22)
                }
                .frame(height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var recommendedSeedGames: [LibraryRecord] {
        library.records
            .sorted {
                let leftPriority = ($0.isFavorite ? 3 : 0) + ($0.status == .playing ? 2 : 0) + ($0.status == .wishlist ? 1 : 0)
                let rightPriority = ($1.isFavorite ? 3 : 0) + ($1.status == .playing ? 2 : 0) + ($1.status == .wishlist ? 1 : 0)
                if leftPriority != rightPriority { return leftPriority > rightPriority }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(4)
            .map { $0 }
    }

    private var libraryDevelopers: [DeveloperRecommendation] {
        let grouped = Dictionary(grouping: library.records) {
            ($0.developer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grouped
            .filter { !$0.key.isEmpty }
            .map { DeveloperRecommendation(name: $0.key, records: $0.value) }
            .sorted {
                if $0.records.count != $1.records.count {
                    return $0.records.count > $1.records.count
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .prefix(6)
            .map { $0 }
    }

    private var libraryDiscoveryTags: [DiscoveryTagRecommendation] {
        var counts: [String: (name: String, count: Int)] = [:]
        for record in library.records {
            for tag in record.discoveryTags ?? [] {
                let key = tag.url.lowercased()
                let current = counts[key]
                counts[key] = (tag.name, (current?.count ?? 0) + 1)
            }
        }
        return counts.map { entry in
            DiscoveryTagRecommendation(
                id: entry.key,
                name: entry.value.name,
                url: entry.key,
                gameCount: entry.value.count
            )
        }
        .sorted {
            if $0.gameCount != $1.gameCount { return $0.gameCount > $1.gameCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .prefix(10)
        .map { $0 }
    }

    private var recommendationURL: URL {
        return URL(string: "https://itch.io/games/genre-visual-novel/tag-adult-themes")!
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(libraryDiscoveryTags.isEmpty ? "编辑精选作品" : "根据你的兴趣推荐")
                        .font(.title3.bold())
                    Text(libraryDiscoveryTags.isEmpty
                         ? "从 itch.io 精选作品中发现新的独立游戏"
                         : "根据「\(libraryDiscoveryTags[0].name)」等游戏标签寻找新作品")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingRecommendations {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        recommendedGames = []
                        isLoadingRecommendations = true
                        // Reloading is triggered by changing the reader URL token.
                        recommendationReloadToken = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("刷新推荐")
                }
            }

            if !recommendedGames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(recommendedGames.prefix(12)) { game in
                            NavigationLink {
                                GameDetailView(game: game)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    AsyncImage(url: game.coverURL) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            RoundedRectangle(cornerRadius: 13)
                                                .fill(Color(uiColor: .tertiarySystemFill))
                                                .overlay {
                                                    Image(systemName: "gamecontroller.fill")
                                                        .foregroundStyle(.tertiary)
                                                }
                                        }
                                    }
                                    .frame(width: 190, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    Text(game.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 190, alignment: .leading)
                                    if let developer = game.developer, !developer.isEmpty {
                                        Text(developer)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 190, alignment: .leading)
                                    }
                                    if let description = game.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(width: 190, alignment: .leading)
                                    }
                                }
                                .frame(width: 190, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if isLoadingRecommendations {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在为你寻找值得玩的作品…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recommendationError ?? "暂时没有获取到推荐作品。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("重新加载") {
                        recommendationReloadToken = UUID()
                        isLoadingRecommendations = true
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private var personalizedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("为你的游戏口味寻找新灵感")
                    .font(.title3.bold())
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color(red: 0.98, green: 0.48, blue: 0.38))
            }
            if !recommendedSeedGames.isEmpty {
                Text("从这些作品继续探索")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(recommendedSeedGames) { record in
                            NavigationLink {
                                ItchSearchResultsView(query: record.title)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottomLeading) {
                                        CachedRemoteImage(url: URL(string: record.coverURL ?? ""), contentMode: .fill) {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(uiColor: .tertiarySystemFill))
                                                .overlay { Image(systemName: "gamecontroller.fill").foregroundStyle(.tertiary) }
                                        }
                                        .frame(width: 158, height: 94)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(record.isFavorite ? "已收藏" : record.status.rawValue)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7).padding(.vertical, 4)
                                            .background(.black.opacity(0.58), in: Capsule()).padding(7)
                                    }
                                    Text(record.title).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary).lineLimit(1)
                                        .frame(width: 158, alignment: .leading)
                                    Text("搜索相关作品").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 158, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("将喜欢的作品加入游戏库，这里就会根据你的收藏和游玩记录提供探索入口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var developerSection: some View {
        Group {
            if !libraryDevelopers.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("你关注过的开发者").font(.title3.bold())
                    ForEach(libraryDevelopers) { developer in
                        NavigationLink {
                            ItchSearchResultsView(query: developer.name)
                        } label: {
                            HStack(spacing: 12) {
                                DeveloperPatreonAvatar(record: developer.records[0])
                                    .frame(width: 44, height: 44).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(developer.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("游戏库中有 \\(developer.records.count) 款作品 · 查看更多作品")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(11)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func performSearch() {
        guard !trimmedSearchText.isEmpty else { return }
        submittedQuery = trimmedSearchText
        showSearchResults = true
    }
}

// MARK: - In-App Search Results

struct ItchSearchResultsView: View {
    let query: String
    var customURL: String? = nil
    var requiresWebLogin: Bool = false

    @AppStorage("itchPocket.webLoginCompleted") private var webLoginCompleted = false
    @AppStorage("itchPocket.appearance") private var appearanceMode = "light"

    var body: some View {
        Group {
            if requiresWebLogin && !webLoginCompleted {
                webLoginGate
            } else {
                ItchWebView(url: localizedURL(searchURL), appearanceMode: appearanceMode)
            }
        }
        .navigationTitle(query.isEmpty ? "浏览 itch.io" : query)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if requiresWebLogin && webLoginCompleted {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重新登录") {
                        webLoginCompleted = false
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var webLoginGate: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("首次连接 itch.io 网页账号", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Text("请在下方登录你的 itch.io 账号。登录成功后，点击“我已登录，继续浏览”。登录状态会保存在本机，全部游戏和免费游戏共用。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            ItchWebView(
                url: URL(string: "https://itch.io/login?locale=zh_Hans")!,
                appearanceMode: appearanceMode
            )

            Button {
                webLoginCompleted = true
            } label: {
                Text("我已登录，继续浏览")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func localizedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "locale" }
        items.append(URLQueryItem(name: "locale", value: "zh_Hans"))
        components.queryItems = items
        return components.url ?? url
    }

    private var searchURL: URL {
        if let customURL, let url = URL(string: customURL) {
            return url
        }

        var components = URLComponents(string: "https://itch.io/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}

// MARK: - WebView

private struct ItchWebView: UIViewRepresentable {
    let url: URL
    let appearanceMode: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        applyAppearance(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        applyAppearance(to: webView)
        if webView.url == nil || webView.url?.host != url.host || webView.url?.path != url.path {
            webView.load(URLRequest(url: url))
        }
    }

    private func applyAppearance(to webView: WKWebView) {
        let style: UIUserInterfaceStyle = appearanceMode == "dark" ? .dark : .light
        webView.overrideUserInterfaceStyle = style
        let colorScheme = appearanceMode == "dark" ? "dark" : "light"
        webView.evaluateJavaScript("document.documentElement.style.colorScheme = '\(colorScheme)';")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ItchWebView

        init(parent: ItchWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.applyAppearance(to: webView)
        }
    }
}


private struct DeveloperPatreonAvatar: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    let record: LibraryRecord
    @State private var avatarURL: URL?

    private var cachedPatreonURL: URL? {
        URL(string: record.patreonAvatarURL ?? "")
    }

    private var fallbackURL: URL? {
        URL(string: record.developerAvatarURL ?? "")
    }

    var body: some View {
        CachedRemoteImage(
            url: avatarURL ?? cachedPatreonURL,
            fallbackURL: fallbackURL,
            contentMode: .fill
        ) {
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .padding(11)
                .foregroundStyle(.secondary)
                .background(Color(uiColor: .tertiarySystemFill))
        }
        .task(id: "\(record.id)|\(record.developerProfileURL ?? "")|\(record.gameURL ?? "")") {
            let resolved = await PatreonAvatarService.shared.avatarURL(
                authorURL: URL(string: record.developerProfileURL ?? ""),
                gameURL: URL(string: record.gameURL ?? "")
            )
            guard let resolved else { return }
            avatarURL = resolved
            if var updated = library.record(for: record.id),
               updated.patreonAvatarURL != resolved.absoluteString {
                updated.patreonAvatarURL = resolved.absoluteString
                library.update(updated)
            }
        }
    }
}


private struct DiscoveryFeedReader: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID
    let onLoad: ([PublicCollectionGame]) -> Void
    let onError: (String) -> Void
    let onStart: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        context.coordinator.url = url
        context.coordinator.reloadToken = reloadToken
        onStart()
        webView.load(URLRequest(url: url, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.url != url || context.coordinator.reloadToken != reloadToken else { return }
        context.coordinator.url = url
        context.coordinator.reloadToken = reloadToken
        onStart()
        webView.load(URLRequest(url: url, timeoutInterval: 30))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DiscoveryFeedReader
        var url: URL
        var reloadToken: UUID

        init(parent: DiscoveryFeedReader) {
            self.parent = parent
            self.url = parent.url
            self.reloadToken = parent.reloadToken
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(Self.script) { result, error in
                if let error {
                    DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
                    return
                }
                guard let json = result as? String, let data = json.data(using: .utf8) else {
                    DispatchQueue.main.async { self.parent.onError("没有读取到可展示的游戏数据。") }
                    return
                }
                do {
                    let games = try JSONDecoder().decode([PublicCollectionGame].self, from: data)
                    DispatchQueue.main.async { self.parent.onLoad(games) }
                } catch {
                    DispatchQueue.main.async { self.parent.onError("推荐数据解析失败：\(error.localizedDescription)") }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
        }

        private static let script = """
        (() => {
          const clean = el => (el?.innerText || el?.textContent || "").replace(/\\s+/g, " ").trim();
          const abs = value => { try { return value ? new URL(value, location.href).href : null; } catch (_) { return null; } };
          const seen = new Set();
          return JSON.stringify(Array.from(document.querySelectorAll(".game_cell")).map(cell => {
            const link = cell.querySelector("a.game_link, .game_title a, a.title, a[href*='itch.io']");
            const href = link ? abs(link.getAttribute("href")) : null;
            const title = clean(cell.querySelector(".game_title, .title")) || clean(link);
            if (!title) return null;
            const id = cell.getAttribute("data-game_id") || href || title;
            if (seen.has(id)) return null;
            seen.add(id);
            const img = cell.querySelector(".game_thumb img, img");
            return {
              id: String(id), title, url: href,
              coverURL: abs(img?.getAttribute("data-lazy_src") || img?.getAttribute("data-lazy-src") || img?.getAttribute("data-src") || img?.currentSrc || img?.getAttribute("src")),
              description: clean(cell.querySelector(".game_text, .game_description, .game_blurb")) || null,
              developer: clean(cell.querySelector(".game_author a, .game_author, .author")) || null,
              developerProfileURL: abs(cell.querySelector(".game_author a[href], .author a[href]")?.getAttribute("href")),
              platforms: Array.from(cell.querySelectorAll(".game_platform, .game_platforms, .web_flag")).map(clean).filter(Boolean)
            };
          }).filter(Boolean));
        })();
        """
    }
}


private struct CuratedDiscoveryFeedReader: UIViewRepresentable {
    let feeds: [DiscoveryFeed]
    let reloadToken: UUID
    let onLoad: (String, [PublicCollectionGame]) -> Void
    let onError: (String) -> Void
    let onStart: () -> Void
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        context.coordinator.begin(in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.reloadToken != reloadToken else { return }
        context.coordinator.reloadToken = reloadToken
        context.coordinator.begin(in: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CuratedDiscoveryFeedReader
        var reloadToken: UUID
        private var index = 0
        private var page = 1
        private var pageGames: [PublicCollectionGame] = []
        private let maximumPages = 4

        init(parent: CuratedDiscoveryFeedReader) {
            self.parent = parent
            self.reloadToken = parent.reloadToken
        }

        func begin(in view: WKWebView) {
            index = 0
            page = 1
            pageGames = []
            parent.onStart()
            loadCurrent(in: view)
        }

        private func loadCurrent(in view: WKWebView) {
            guard index < parent.feeds.count else {
                DispatchQueue.main.async { self.parent.onFinish() }
                return
            }
            guard var components = URLComponents(url: parent.feeds[index].url, resolvingAgainstBaseURL: false) else {
                advanceFeed(in: view)
                return
            }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "page" }
            if page > 1 {
                components.queryItems?.append(URLQueryItem(name: "page", value: String(page)))
            }
            guard let url = components.url else {
                advanceFeed(in: view)
                return
            }
            view.load(URLRequest(url: url, timeoutInterval: 30))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard index < parent.feeds.count else { return }
            let feed = parent.feeds[index]
            webView.evaluateJavaScript(Self.script) { result, error in
                if let error {
                    DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
                    self.advanceFeed(in: webView)
                    return
                }
                guard let json = result as? String else {
                    DispatchQueue.main.async { self.parent.onError("没有读取到作品列表。") }
                    self.advanceFeed(in: webView)
                    return
                }
                if json == "AGE_GATE" {
                    DispatchQueue.main.async {
                        self.parent.onError("itch.io 要求先确认 18+ 才能读取成人作品。请进入下方页面完成确认，再点右上角刷新。")
                    }
                    self.advanceFeed(in: webView)
                    return
                }
                guard let data = json.data(using: .utf8) else {
                    DispatchQueue.main.async { self.parent.onError("推荐数据格式无效。") }
                    self.advanceFeed(in: webView)
                    return
                }
                do {
                    let games = try JSONDecoder().decode([PublicCollectionGame].self, from: data)
                    var seen = Set(self.pageGames.map { $0.id })
                    self.pageGames.append(contentsOf: games.filter { seen.insert($0.id).inserted })
                    DispatchQueue.main.async { self.parent.onLoad(feed.id, self.pageGames) }
                    if games.isEmpty || self.page >= self.maximumPages {
                        self.advanceFeed(in: webView)
                    } else {
                        self.page += 1
                        self.loadCurrent(in: webView)
                    }
                } catch {
                    DispatchQueue.main.async { self.parent.onError("推荐数据解析失败：\\(error.localizedDescription)") }
                    self.advanceFeed(in: webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Loading the next page cancels the previous navigation by design.
            // A cancellation must not advance to the next feed or discard pagination state.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
            advanceFeed(in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async { self.parent.onError(error.localizedDescription) }
            advanceFeed(in: webView)
        }

        private func advanceFeed(in view: WKWebView) {
            index += 1
            page = 1
            pageGames = []
            loadCurrent(in: view)
        }

        private static let script = """
        (() => {
          if (/You must be 18\\+ to view this content/i.test(document.body?.innerText || "")) return "AGE_GATE";
          const clean = el => (el?.innerText || el?.textContent || "").replace(/\\s+/g, " ").trim();
          const abs = value => { try { return value ? new URL(value, location.href).href : null; } catch (_) { return null; } };
          const seen = new Set();
          return JSON.stringify(Array.from(document.querySelectorAll(".game_cell")).map(cell => {
            const link = cell.querySelector("a.game_link, .game_title a, a.title, a[href*='itch.io']");
            const href = link ? abs(link.getAttribute("href")) : null;
            const title = clean(cell.querySelector(".game_title, .title")) || clean(link);
            if (!title) return null;
            const id = cell.getAttribute("data-game_id") || href || title;
            if (seen.has(id)) return null;
            seen.add(id);
            const img = cell.querySelector(".game_thumb img, img");
            return {
              id: String(id), title, url: href,
              coverURL: abs(img?.getAttribute("data-lazy_src") || img?.getAttribute("data-lazy-src") || img?.getAttribute("data-src") || img?.currentSrc || img?.getAttribute("src")),
              description: clean(cell.querySelector(".game_text, .game_description, .game_blurb")) || null,
              developer: clean(cell.querySelector(".game_author a, .game_author, .author")) || null,
              developerProfileURL: abs(cell.querySelector(".game_author a[href], .author a[href]")?.getAttribute("href")),
              platforms: Array.from(cell.querySelectorAll(".game_platform, .game_platforms, .web_flag")).map(clean).filter(Boolean)
            };
          }).filter(Boolean));
        })();
        """
    }
}
