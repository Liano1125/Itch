import SwiftUI
import WebKit

struct DiscoverView: View {
    @EnvironmentObject private var library: PersonalLibraryStore
    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var showSearchResults = false

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    searchBar
                    featuredSection
                    libraryDiscoverySection
                    browseSection
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

            Text("发现好玩的\n独立游戏")
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

    private var libraryDevelopers: [LibraryRecord] {
        var seen = Set<String>()
        return library.records.filter { record in
            guard let developer = record.developer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !developer.isEmpty else { return false }
            return seen.insert(developer.lowercased()).inserted
        }.prefix(6).map { $0 }
    }

    @ViewBuilder
    private var libraryDiscoverySection: some View {
        if !libraryDevelopers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("从你的游戏库继续发现")
                    .font(.title3.bold())

                ForEach(libraryDevelopers) { record in
                    NavigationLink {
                        ItchSearchResultsView(query: record.developer ?? "")
                    } label: {
                        HStack(spacing: 12) {
                            DeveloperPatreonAvatar(record: record)
                                .frame(width: 46, height: 46)
                                .clipShape(Circle())
                            Text(record.developer ?? "")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("探索游戏")
                .font(.title3.bold())

            explorationGroup(
                title: "热门榜单",
                items: [
                    ("热门游戏", "flame.fill", "https://itch.io/games"),
                    ("评分最高", "star.fill", "https://itch.io/games/top-rated"),
                    ("最新上架", "clock.fill", "https://itch.io/games/newest"),
                    ("免费游戏", "gift.fill", "https://itch.io/games/price-free")
                ]
            )

            explorationGroup(
                title: "游戏类型",
                items: [
                    ("冒险", "map.fill", "https://itch.io/games/genre-adventure"),
                    ("角色扮演", "person.fill", "https://itch.io/games/genre-rpg"),
                    ("解谜", "puzzlepiece.fill", "https://itch.io/games/genre-puzzle"),
                    ("动作", "bolt.fill", "https://itch.io/games/genre-action"),
                    ("模拟", "slider.horizontal.3", "https://itch.io/games/genre-simulation"),
                    ("恐怖", "moon.fill", "https://itch.io/games/genre-horror"),
                    ("策略", "棋盘图标占位", "https://itch.io/games/genre-strategy"),
                    ("平台跳跃", "figure.run", "https://itch.io/games/genre-platformer")
                ]
            )

            explorationGroup(
                title: "游戏平台",
                items: [
                    ("Windows", "desktopcomputer", "https://itch.io/games/platform-windows"),
                    ("macOS", "laptopcomputer", "https://itch.io/games/platform-osx"),
                    ("Linux", "terminal.fill", "https://itch.io/games/platform-linux"),
                    ("浏览器", "globe", "https://itch.io/games/platform-web")
                ]
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("更多发现")
                    .font(.headline)
                browseRow(
                    title: "全部游戏",
                    subtitle: "探索 itch.io 的完整游戏目录",
                    symbol: "square.grid.2x2.fill",
                    tint: .blue,
                    url: "https://itch.io/games",
                    requiresWebLogin: true
                )
                browseRow(
                    title: "Game Jam",
                    subtitle: "看看独立开发者正在参与的创作活动",
                    symbol: "timer",
                    tint: .orange,
                    url: "https://itch.io/jams"
                )
            }
        }
    }

    private func explorationGroup(
        title: String,
        items: [(String, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(items, id: \.0) { item in
                    NavigationLink {
                        ItchSearchResultsView(query: "", customURL: item.2)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.1 == "棋盘图标占位" ? "square.grid.3x3.fill" : item.1)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                            Text(item.0)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func browseRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        url: String,
        requiresWebLogin: Bool = false
    ) -> some View {
        NavigationLink {
            ItchSearchResultsView(
                query: "",
                customURL: url,
                requiresWebLogin: requiresWebLogin
            )
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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

    private var fallbackURL: URL? {
        URL(string: record.patreonAvatarURL ?? "")
    }

    var body: some View {
        CachedRemoteImage(url: avatarURL ?? fallbackURL, contentMode: .fill) {
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .padding(11)
                .foregroundStyle(.secondary)
                .background(Color(uiColor: .tertiarySystemFill))
        }
        .task(id: record.id) {
            let resolved = await PatreonAvatarService.shared.avatarURL(
                authorURL: URL(string: record.developerProfileURL ?? ""),
                gameURL: URL(string: record.gameURL ?? ""),
                fallbackURL: fallbackURL
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
