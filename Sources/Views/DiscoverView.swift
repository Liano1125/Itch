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
    let id: String
    let name: String
    let records: [LibraryRecord]

    var avatarRecord: LibraryRecord {
        records.first(where: { $0.developerAvatarURL != nil || $0.patreonAvatarURL != nil })
            ?? records.first(where: { $0.developerProfileURL != nil })
            ?? records[0]
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var showSearchResults = false
    @State private var curatedGames: [String: [PublicCollectionGame]]
    @State private var isLoadingCurated = false
    @State private var curatedError: String?
    @State private var didCheckCuratedRefresh = false

    init() {
        _curatedGames = State(initialValue: Self.loadCuratedCache())
    }

    private static let curatedCacheKey = "itchPocket.curatedFeeds.v1"

    private static func loadCuratedCache() -> [String: [PublicCollectionGame]] {
        if let snapshot = DiscoveryFeedSnapshotCache.load() {
            return snapshot
        }

        // One-time compatibility bridge for snapshots written by the previous
        // SwiftData-backed cache. New discovery snapshots stay out of the
        // canonical entity database.
        let legacy = DiscoveryCacheStore.load(
            [String: [PublicCollectionGame]].self,
            key: curatedCacheKey
        ) ?? [:]
        if !legacy.isEmpty { DiscoveryFeedSnapshotCache.save(legacy) }
        return legacy
    }

    private func persistCuratedCache() {
        let compact = curatedGames.mapValues { Array($0.prefix(24)) }
        DiscoveryFeedSnapshotCache.save(compact)
    }

    @MainActor
    private func refreshCuratedFeeds() async {
        guard !isLoadingCurated else { return }
        isLoadingCurated = true
        curatedError = nil
        var errors: [String] = []

        // Fetch one category at a time to limit concurrent work and memory use.
        for feed in DiscoveryFeed.curated {
            do {
                let games = try await DiscoveryFeedClient.shared.fetchGames(from: feed.url)
                // Never replace a useful snapshot with an unexpectedly empty response.
                if !games.isEmpty || curatedGames[feed.id] == nil {
                    curatedGames[feed.id] = games
                    persistCuratedCache()
                }
            } catch {
                errors.append("\\(feed.title)：\\(error.localizedDescription)")
            }
        }

        if DiscoveryFeed.curated.allSatisfy({ (curatedGames[$0.id] ?? []).isEmpty }), !errors.isEmpty {
            curatedError = errors.joined(separator: "\\n")
        }
        isLoadingCurated = false
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
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
            .navigationDestination(isPresented: $showSearchResults) {
                ItchSearchResultsView(query: submittedQuery)
            }
            .task {
                guard !didCheckCuratedRefresh else { return }
                didCheckCuratedRefresh = true
                guard DiscoveryFeedSnapshotCache.needsRefresh() else { return }
                // Render cached cards first; the native URLSession refresh starts
                // only after the initial frame and never creates a WKWebView.
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await refreshCuratedFeeds()
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

            Text("发现值得玩的 Ren'Py 游戏")
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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                        Task { await refreshCuratedFeeds() }
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
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(games.prefix(12)) { game in
                            NavigationLink {
                                GameDetailView(
                                    game: game,
                                    parserProfile: feed.id == "adjacent-renpy" ? .adultRenPy : .adult3D
                                )
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
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
                VStack(alignment: .leading, spacing: 5) {
                    Text("暂时没有缓存作品")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("点击上方刷新后，作品会在后台读取并缓存。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
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
        let grouped = Dictionary(grouping: library.records) { record -> String in
            if let profileURL = record.developerProfileURL, !profileURL.isEmpty {
                return profileURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return "name:" + (record.developer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return grouped
            .filter { !($0.value.first?.developer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { key, records in
                DeveloperRecommendation(id: key, name: records[0].developer ?? key, records: records)
            }
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
                    LazyHStack(spacing: 11) {
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
                                DeveloperPatreonAvatar(record: developer.avatarRecord)
                                    .frame(width: 44, height: 44).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(developer.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(11)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
    let record: LibraryRecord
    @State private var avatarURL: URL?

    private var storedAvatarURL: URL? {
        [record.developerAvatarURL, record.patreonAvatarURL]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first
    }

    var body: some View {
        CachedRemoteImage(
            url: storedAvatarURL ?? avatarURL,
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
            avatarURL = await PatreonAvatarService.shared.avatarURL(
                authorURL: URL(string: record.developerProfileURL ?? ""),
                gameURL: URL(string: record.gameURL ?? "")
            )
        }
    }
}
