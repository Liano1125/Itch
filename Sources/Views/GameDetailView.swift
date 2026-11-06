import SwiftUI
import WebKit
import Foundation

// MARK: - Models

private struct GamePagePayload: Decodable {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let galleryURLs: [URL]?
    let authorURL: URL?
    let authorAvatarURL: URL?
    let patreonURL: URL?
    let discordURL: URL?
    let scriptError: String?
}

private struct GameDetailPayload {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let galleryURLs: [URL]
    let authorURL: URL?
    let authorAvatarURL: URL?
    let patreonURL: URL?
    let discordURL: URL?
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let game: PublicCollectionGame

    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var library: PersonalLibraryStore

    @State private var detail: GameDetailPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()
    @State private var translatedDescription: String?
    @State private var translatedUpdates: [String: String] = [:]
    @State private var translationStatus: String?
    @State private var selectedGalleryIndex = 0
    @State private var showingGalleryViewer = false

    private var displayCover: URL? {
        detail?.coverURL ?? game.coverURL
    }

    private var displayDeveloper: String? {
        detail?.developer ?? game.developer
    }

    private var displayDescription: String? {
        detail?.description ?? game.description
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                gallerySection
                coverSection
                titleSection
                authorSection
                linksSection

                Divider()

                descriptionSection
                statusHistorySection
                gameUpdateHistorySection

                if let errorMessage {
                    errorSection(errorMessage)
                }

                originalPageButton
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: reloadDetail) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .sheet(isPresented: $showingGalleryViewer) {
            galleryViewer
        }
        .overlay {
            DetailPageReader(
                url: game.url,
                reloadToken: reloadToken,
                onLoad: handleLoadedDetail,
                onError: handleLoadError
            )
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Cover

    private var coverSection: some View {
        GeometryReader { geometry in
            ZStack {
                if let url = displayCover {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height
                                )
                                .clipped()

                        case .failure:
                            coverPlaceholder

                        case .empty:
                            ZStack {
                                RoundedRectangle(cornerRadius: 20)
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
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .clipped()
        }
        .aspectRatio(1.45, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.quaternary)

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Gallery

    @ViewBuilder
    private var gallerySection: some View {
        let images = detail?.galleryURLs ?? []
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("游戏图库").font(.title3.bold())
                    Spacer()
                    Text("\(images.count) 张截图").font(.caption).foregroundStyle(.secondary)
                }
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: images[min(selectedGalleryIndex, images.count - 1)]) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 20).fill(.quaternary)
                                .overlay { ProgressView() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 232)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { showingGalleryViewer = true }

                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .allowsHitTesting(false)

                    HStack(alignment: .bottom) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: -13) {
                                ForEach(Array(images.prefix(7).enumerated()), id: \.offset) { index, url in
                                    Button {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                            selectedGalleryIndex = index
                                        }
                                    } label: {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().scaledToFill()
                                            } else {
                                                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                                            }
                                        }
                                        .frame(width: 70, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(selectedGalleryIndex == index ? Color.white : Color.white.opacity(0.65), lineWidth: selectedGalleryIndex == index ? 2.5 : 1)
                                        }
                                        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .zIndex(selectedGalleryIndex == index ? 2 : 1)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                        Spacer(minLength: 2)
                        Button { showingGalleryViewer = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 5)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var galleryViewer: some View {
        NavigationStack {
            TabView(selection: $selectedGalleryIndex) {
                ForEach(Array((detail?.galleryURLs ?? []).enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .tag(index)
                    .background(Color.black)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingGalleryViewer = false }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(game.title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let developer = displayDeveloper, !developer.isEmpty {
                Text(developer).font(.subheadline).foregroundStyle(.secondary)
            }

            if !game.platforms.isEmpty {
                HStack(spacing: 7) {
                    ForEach(game.platforms, id: \.self) { platform in
                        Text(platform)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Author and Links

    @ViewBuilder
    private var authorSection: some View {
        if let developer = displayDeveloper, !developer.isEmpty {
            NavigationLink {
                if let url = detail?.authorURL {
                    AuthorProfileView(name: developer, url: url)
                } else if let url = game.url {
                    AuthorProfileView(name: developer, url: url)
                }
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: detail?.authorAvatarURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Image(systemName: "person.fill").resizable().scaledToFit().padding(12).foregroundStyle(.secondary).background(.quaternary) }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("游戏作者").font(.caption).foregroundStyle(.secondary)
                        Text(developer).font(.headline).foregroundStyle(.primary)
                        Text("查看作者的游戏与动态").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(13)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        let patreon = detail?.patreonURL
        let discord = detail?.discordURL
        if patreon != nil || discord != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Link").font(.title3.bold())
                HStack(spacing: 10) {
                    if let patreon {
                        Link(destination: patreon) {
                            Label("Patreon", systemImage: "heart.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if let discord {
                        Link(destination: discord) {
                            Label("Discord", systemImage: "bubble.left.and.bubble.right.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("游戏介绍")
                .font(.title2.bold())

            if let description = displayDescription,
               !description.isEmpty {
                Text(translatedDescription ?? description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let translationStatus {
                    Text(translationStatus).font(.caption).foregroundStyle(.secondary)
                }
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取游戏介绍…")
                        .foregroundStyle(.secondary)
                }

            } else {
                Text("暂时无法读取游戏介绍。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Status History

    @ViewBuilder
    private var statusHistorySection: some View {
        if library.record(for: game.id) != nil {
            VStack(alignment: .leading, spacing: 13) {
                Text("状态记录")
                    .font(.title2.bold())

                let events = library.history(for: game.id)
                if events.isEmpty {
                    Text("从现在开始，游戏状态的每次变化都会记录在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: event.toStatus.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.fromStatus.map { "\($0.rawValue) → \(event.toStatus.rawValue)" } ?? "加入个人游戏库")
                                        .font(.subheadline.weight(.semibold))
                                    Text(event.changedAt.formatted(date: .long, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Game Update History

    @ViewBuilder
    private var gameUpdateHistorySection: some View {
        if library.record(for: game.id) != nil {
            let updates = library.updates(for: game.id)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("游戏更新记录")
                        .font(.title2.bold())
                    Spacer()
                    if !updates.isEmpty {
                        Text("\(updates.count) 条")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if updates.isEmpty {
                    Text("检测到的页面更新会同步显示在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(updates) { update in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                let translated = translatedUpdates[update.id]
                                Text(translated ?? update.title ?? update.summary)
                                    .font(.subheadline.weight(.semibold))
                                if !(update.summary.isEmpty) && update.title != nil {
                                    Text(translated == nil ? update.summary : translated!.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                }
                                Text((update.publishedAt ?? update.detectedAt).formatted(date: .long, time: .shortened) + ((update.isHistorical ?? false) ? " · 原始发布日期" : " · 检测时间"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let rawURL = update.url, let postURL = URL(string: rawURL) {
                                    Link("查看 itch.io 更新原文", destination: postURL)
                                        .font(.caption.weight(.medium))
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Error

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "部分详情读取失败",
                systemImage: "exclamationmark.triangle"
            )
            .font(.subheadline.weight(.medium))

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("重新读取", action: reloadDetail)
                .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: Original Page

    private var originalPageButton: some View {
        Group {
            if let url = game.url {
                Button {
                    openURL(url)
                } label: {
                    Label(
                        "在 itch.io 查看完整游戏页面",
                        systemImage: "safari"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Data Handling

    private func handleLoadedDetail(_ result: GameDetailPayload) {
        detail = result
        translatedDescription = nil
        translatedUpdates = [:]
        translationStatus = nil
        selectedGalleryIndex = 0
        isLoading = false
        errorMessage = nil
        Task { await translateContent() }
    }

    private func translateContent() async {
        guard TranslationService.isConfigured else {
            translationStatus = "请在「我的 - 翻译设置」配置翻译服务。"
            return
        }
        translationStatus = "正在翻译…"
        do {
            if let description = displayDescription, !description.isEmpty {
                translatedDescription = try await TranslationService.translate(description)
            }
            for update in library.updates(for: game.id) {
                let source = [update.title, update.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                guard !source.isEmpty else { continue }
                do {
                    translatedUpdates[update.id] = try await TranslationService.translate(source)
                } catch {
                    // A failed individual update must not block the rest of the detail page.
                }
            }
            translationStatus = "已尝试翻译介绍和更新记录"
        } catch {
            translationStatus = "翻译失败：\(error.localizedDescription)"
        }
    }

    private func handleLoadError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    private func reloadDetail() {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        detail = nil
        reloadToken = UUID()
    }
}

// MARK: - Game Page Reader

private struct DetailPageReader: UIViewRepresentable {
    let url: URL?
    let reloadToken: UUID
    let onLoad: (GameDetailPayload) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )

        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        context.coordinator.currentToken = reloadToken

        guard let url else {
            DispatchQueue.main.async {
                context.coordinator.parent.onError("游戏页面地址无效。")
            }
            return webView
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)

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
        context.coordinator.finished = false

        guard let url else {
            onError("游戏页面地址无效。")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DetailPageReader
        var currentToken: UUID?
        var finished = false

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            finished = false

            webView.evaluateJavaScript(Self.gamePageScript) { result, error in
                guard !self.finished else { return }

                if let error {
                    self.fail(
                        "读取游戏主页失败：\(error.localizedDescription)"
                    )
                    return
                }

                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(
                        GamePagePayload.self,
                        from: data
                      ) else {
                    self.fail("游戏主页返回的数据无法解析。请重新读取。")
                    return
                }

                if let scriptError = payload.scriptError {
                    self.fail("游戏主页 JavaScript 错误：\(scriptError)")
                    return
                }

                self.finished = true

                DispatchQueue.main.async {
                    self.parent.onLoad(
                        GameDetailPayload(
                            description: payload.description,
                            developer: payload.developer,
                            coverURL: payload.coverURL,
                            galleryURLs: payload.galleryURLs ?? [],
                            authorURL: payload.authorURL,
                            authorAvatarURL: payload.authorAvatarURL,
                            patreonURL: payload.patreonURL,
                            discordURL: payload.discordURL
                        )
                    )
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
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }

            fail(
                "无法打开 itch.io 游戏页面：\(error.localizedDescription)"
            )
        }

        private func fail(_ message: String) {
            guard !finished else { return }
            finished = true

            DispatchQueue.main.async {
                self.parent.onError(message)
            }
        }

        private static let gamePageScript = """
        (() => {
            try {
                const clean = el => {
                    const value = el?.innerText || el?.textContent || "";
                    return value.replace(/\\s+/g, " ").trim();
                };

                const absolute = value => {
                    try {
                        return value ? new URL(value, location.href).href : null;
                    } catch (_) {
                        return null;
                    }
                };

                let description = null;
                const descriptionSelectors = [
                    ".formatted_description",
                    ".game_page_content .formatted_description",
                    ".game_description",
                    "#game_description"
                ];

                for (const selector of descriptionSelectors) {
                    const value = clean(document.querySelector(selector));
                    if (value.length > 20) {
                        description = value;
                        break;
                    }
                }

                if (!description) {
                    description =
                        document.querySelector('meta[name="description"]')
                        ?.getAttribute("content") || null;
                }

                let developer = null;
                const developerSelectors = [
                    ".game_author a",
                    ".game_author",
                    ".header_links .user_link",
                    ".user_link"
                ];

                for (const selector of developerSelectors) {
                    const value = clean(document.querySelector(selector));
                    if (value) {
                        developer = value;
                        break;
                    }
                }

                let coverURL = null;
                const coverSelectors = [
                    'meta[property="og:image"]',
                    'meta[name="twitter:image"]',
                    ".game_cover img",
                    ".game_thumb img",
                    ".screenshot img"
                ];

                for (const selector of coverSelectors) {
                    const el = document.querySelector(selector);
                    if (!el) continue;

                    const value = absolute(
                        el.getAttribute("content") ||
                        el.currentSrc ||
                        el.getAttribute("data-lazy_src") ||
                        el.getAttribute("data-lazy-src") ||
                        el.getAttribute("data-src") ||
                        el.getAttribute("src")
                    );

                    if (value) {
                        coverURL = value;
                        break;
                    }
                }

                // itch.io screenshot images are linked to their original-size asset.
                // Read the anchor href first (usually /original/...), then fall back to lazy-loaded img sources.
                const galleryCandidates = [];
                const screenshotAnchors = Array.from(document.querySelectorAll(
                    '.screenshot_list a[data-image_lightbox], .screenshot_container a[data-image_lightbox], .screenshot a[data-image_lightbox], #game_screenshots a, .game_page_screenshots a, a[data-image_lightbox]'
                ));
                for (const anchor of screenshotAnchors) {
                    const image = anchor.querySelector("img");
                    const href = absolute(anchor.getAttribute("href"));
                    const imageSource = absolute(
                        image?.getAttribute("data-lazy_src") || image?.getAttribute("data-lazy-src") ||
                        image?.getAttribute("data-src") || image?.currentSrc || image?.getAttribute("srcset")?.split(/\\s+/)[0] || image?.getAttribute("src")
                    );
                    const candidate = href && /img\\.itch\\.zone|\\.(png|jpe?g|webp|gif)(\\?|$)/i.test(href) ? href : imageSource;
                    if (candidate) galleryCandidates.push(candidate);
                }
                const screenshotImages = Array.from(document.querySelectorAll(
                    'img.screenshot, .screenshot_list img, .screenshot_container img, .screenshot img, #game_screenshots img, .game_page_screenshots img'
                ));
                for (const image of screenshotImages) {
                    const source = absolute(
                        image.getAttribute("data-lazy_src") || image.getAttribute("data-lazy-src") ||
                        image.getAttribute("data-src") || image.currentSrc || image.getAttribute("srcset")?.split(/\\s+/)[0] || image.getAttribute("src")
                    );
                    if (source) galleryCandidates.push(source);
                }
                const galleryURLs = galleryCandidates
                    .filter(value => /img\\.itch\\.zone|\\.(png|jpe?g|webp|gif)(\\?|$)/i.test(value))
                    .filter((value, index, array) => array.indexOf(value) === index)
                    .slice(0, 30);

                const authorLink = document.querySelector(".game_author a[href], .header_links .user_link[href], a.user_link[href]");
                const authorURL = authorLink ? absolute(authorLink.getAttribute("href")) : null;
                const authorAvatar = document.querySelector(".game_author img, .user_avatar img, .user_link img, .header_links img");
                const authorAvatarURL = authorAvatar ? absolute(
                    authorAvatar.getAttribute("data-lazy_src") || authorAvatar.getAttribute("data-src") || authorAvatar.currentSrc || authorAvatar.getAttribute("src")
                ) : null;

                const links = Array.from(document.querySelectorAll("a[href]")).map(a => absolute(a.getAttribute("href"))).filter(Boolean);
                const patreonURL = links.find(value => /(^|\\.)patreon\\.com$/i.test(new URL(value).hostname)) || null;
                const discordURL = links.find(value => /(^|\\.)discord\\.(gg|com)$/i.test(new URL(value).hostname) || /discord\\.com\\/invite\\//i.test(value)) || null;

                return JSON.stringify({
                    description,
                    developer,
                    coverURL,
                    galleryURLs,
                    authorURL,
                    authorAvatarURL,
                    patreonURL,
                    discordURL,
                    scriptError: null
                });
            } catch (error) {
                return JSON.stringify({
                    description: null,
                    developer: null,
                    coverURL: null,
                    galleryURLs: [],
                    authorURL: null,
                    authorAvatarURL: null,
                    patreonURL: null,
                    discordURL: null,
                    scriptError: String(error)
                });
            }
        })();
        """
    }
}
