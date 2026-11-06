
import SwiftUI
import WebKit

// MARK: - Public Collection Configuration

private enum ItchPublicCollection {
    static let url = URL(
        string: "https://itch.io/c/5891862/liano1125s-collection"
    )!
}

// MARK: - Public Game Model

private struct PublicCollectionGame: Decodable, Identifiable {
    let id: String
    let title: String
    let url: URL?
    let coverURL: URL?
    let description: String?
    let developer: String?
    let platforms: [String]
}

// MARK: - Library View

struct LibraryView: View {
    @State private var games: [PublicCollectionGame] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var filteredGames: [PublicCollectionGame] {
        guard !searchText.isEmpty else {
            return games
        }

        return games.filter { game in
            game.title.localizedCaseInsensitiveContains(searchText)
            || (game.developer ?? "")
                .localizedCaseInsensitiveContains(searchText)
            || (game.description ?? "")
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 隐藏的网页读取器，只负责获取公开合集数据
                ItchCollectionPageReader(
                    url: ItchPublicCollection.url,
                    reloadToken: reloadToken,
                    onLoad: handleLoadedGames,
                    onError: handleLoadError
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                content
            }
            .navigationTitle("游戏库")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                prompt: "搜索我的游戏"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadGames()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("刷新游戏库")
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
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

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的游戏")
                        .font(.title2.bold())

                    HStack(spacing: 6) {
                        Text("\(games.count) 款游戏")

                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if filteredGames.isEmpty {
                    ContentUnavailableView(
                        "没有找到游戏",
                        systemImage: "magnifyingglass",
                        description: Text(
                            "试试其他游戏名称、开发者或关键词"
                        )
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: columns,
                        spacing: 16
                    ) {
                        ForEach(filteredGames) { game in
                            PublicGameCard(game: game)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding()
        }
        .refreshable {
            reloadGames()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("正在读取你的 18 款游戏…")
                .foregroundStyle(.secondary)

            Text("正在连接 itch.io 公开合集")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        ContentUnavailableView(
            "没有找到游戏",
            systemImage: "gamecontroller",
            description: Text(
                "暂时没有从公开合集页面读取到游戏，请尝试刷新。"
            )
        )
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                "读取游戏库失败",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button("重新加载") {
                reloadGames()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Data Handling

    private func handleLoadedGames(
        _ result: [PublicCollectionGame]
    ) {
        games = result
        isLoading = false
        hasLoaded = true
        errorMessage = nil
    }

    private func handleLoadError(_ message: String) {
        isLoading = false
        hasLoaded = true
        errorMessage = message
    }

    private func reloadGames() {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil
        games = []
        hasLoaded = false
        reloadToken = UUID()
    }
}

// MARK: - Public Game Card

private struct PublicGameCard: View {
    let game: PublicCollectionGame

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            cover

            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )

            if let description = game.description,
               !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }

            if let developer = game.developer,
               !developer.isEmpty {
                Text(developer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !game.platforms.isEmpty {
                HStack(spacing: 6) {
                    ForEach(
                        Array(game.platforms.prefix(5).enumerated()),
                        id: \.offset
                    ) { _, platform in
                        Text(platform)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

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

    @ViewBuilder
    private var cover: some View {
        if let url = game.coverURL {
            AsyncImage(url: url) { phase in
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
            .frame(maxWidth: .infinity)
            .aspectRatio(1.26, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 13))
        } else {
            coverPlaceholder
                .frame(maxWidth: .infinity)
                .aspectRatio(1.26, contentMode: .fit)
        }
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

// MARK: - Hidden Collection Web Reader

private struct ItchCollectionPageReader: UIViewRepresentable {
    let url: URL
    let reloadToken: UUID

    let onLoad: ([PublicCollectionGame]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        context.coordinator.currentToken = reloadToken

        webView.load(
            URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
        )

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        context.coordinator.parent = self

        guard context.coordinator.currentToken != reloadToken else {
            return
        }

        context.coordinator.currentToken = reloadToken

        webView.load(
            URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ItchCollectionPageReader
        var currentToken: UUID?

        init(parent: ItchCollectionPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            webView.evaluateJavaScript(
                Self.extractionScript
            ) { result, error in

                if let error {
                    DispatchQueue.main.async {
                        self.parent.onError(
                            "解析合集页面失败：\(error.localizedDescription)"
                        )
                    }
                    return
                }

                guard let json = result as? String,
                      let data = json.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        self.parent.onError(
                            "合集页面没有返回有效的游戏数据。"
                        )
                    }
                    return
                }

                do {
                    let games = try JSONDecoder().decode(
                        [PublicCollectionGame].self,
                        from: data
                    )

                    DispatchQueue.main.async {
                        self.parent.onLoad(games)
                    }

                } catch {
                    DispatchQueue.main.async {
                        self.parent.onError(
                            "游戏数据解码失败：\(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            DispatchQueue.main.async {
                self.parent.onError(
                    "无法打开 itch.io 公开合集：\(error.localizedDescription)"
                )
            }
        }

        // MARK: - JavaScript Extraction

        private static let extractionScript = """
        (() => {
            const cleanText = (element) => {
                if (!element) return "";
                return (element.innerText || element.textContent || "")
                    .replace(/\\s+/g, " ")
                    .trim();
            };

            const absoluteURL = (value) => {
                if (!value) return null;

                try {
                    return new URL(value, location.href).href;
                } catch (_) {
                    return null;
                }
            };

            const cells = Array.from(
                document.querySelectorAll(".game_cell")
            );

            const games = [];
            const seen = new Set();

            for (const cell of cells) {
                const titleElement = cell.querySelector(
                    ".game_title, .title, .game_title a, a.title"
                );

                const links = Array.from(
                    cell.querySelectorAll("a[href]")
                );

                const gameLink =
                    cell.querySelector(
                        "a.game_link, .game_title a, a.title"
                    ) ||
                    links.find(a => {
                        try {
                            const host = new URL(a.href).hostname;
                            return host === "itch.io" ||
                                   host.endsWith(".itch.io");
                        } catch (_) {
                            return false;
                        }
                    }) ||
                    links[0];

                const gameURL = gameLink
                    ? absoluteURL(gameLink.getAttribute("href"))
                    : null;

                let title = cleanText(titleElement);

                if (!title && gameLink) {
                    title = cleanText(gameLink);
                }

                if (!title) continue;

                const identity =
                    gameURL ||
                    cell.getAttribute("data-game_id") ||
                    title;

                if (seen.has(identity)) continue;
                seen.add(identity);

                const image = cell.querySelector(
                    ".game_thumb img, img.game_thumb, .game_thumb picture img, img"
                );

                let coverURL = null;

                if (image) {
                    coverURL = absoluteURL(
                        image.getAttribute("data-lazy_src") ||
                        image.getAttribute("data-lazy-src") ||
                        image.getAttribute("data-src") ||
                        image.currentSrc ||
                        image.getAttribute("src")
                    );
                }

                const descriptionElement = cell.querySelector(
                    ".game_text, .game_description, .game_blurb, .game_desc"
                );

                const developerElement = cell.querySelector(
                    ".game_author a, .game_author, .author"
                );

                const platformElements = Array.from(
                    cell.querySelectorAll(
                        ".game_platform, .game_platforms, .web_flag"
                    )
                );

                const platforms = platformElements
                    .map(cleanText)
                    .filter(Boolean);

                games.push({
                    id: String(
                        cell.getAttribute("data-game_id") ||
                        gameURL ||
                        identity
                    ),
                    title: title,
                    url: gameURL,
                    coverURL: coverURL,
                    description: cleanText(descriptionElement) || null,
                    developer: cleanText(developerElement) || null,
                    platforms: platforms
                });
            }

            return JSON.stringify(games);
        })();
        """
    }
}
