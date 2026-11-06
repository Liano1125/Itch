
import SwiftUI
import WebKit

// MARK: - Models

private struct GamePagePayload: Decodable {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let downloadURL: URL?
}

private struct GameDetailPayload {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let uploads: [GameUpload]
}

private struct GameUpload: Identifiable {
    let id: String
    let name: String
    let url: URL
    let fileSize: String?
    let provider: String
    let isDirectDownload: Bool
}

private struct DownloadPagePayload: Decodable {
    let uploads: [DownloadItem]

    struct DownloadItem: Decodable {
        let id: String
        let name: String
        let url: URL
        let fileSize: String?
        let provider: String
        let isDirectDownload: Bool
    }
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let game: PublicCollectionGame

    @Environment(\.openURL) private var openURL

    @State private var detail: GameDetailPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    @State private var downloadingIDs: Set<String> = []
    @State private var downloadedFiles: [String: URL] = [:]

    @State private var downloadMessage: String?
    @State private var showingDownloadMessage = false

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
                coverSection
                titleSection

                Divider()

                descriptionSection
                uploadsSection

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
                Button {
                    reloadDetail()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
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
        .alert("下载", isPresented: $showingDownloadMessage) {
            Button("好", role: .cancel) { }
        } message: {
            Text(downloadMessage ?? "")
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

    // MARK: Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(game.title)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)

            if let developer = displayDeveloper,
               !developer.isEmpty {
                Label(
                    developer,
                    systemImage: "person"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("游戏介绍")
                .font(.title2.bold())

            if let description = displayDescription,
               !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

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

    // MARK: Downloads

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("下载文件")
                    .font(.title2.bold())

                Spacer()

                if let uploads = detail?.uploads,
                   !uploads.isEmpty {
                    Text("\(uploads.count) 个选项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && detail == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取下载选项…")
                        .foregroundStyle(.secondary)
                }

            } else if let uploads = detail?.uploads,
                      !uploads.isEmpty {
                ForEach(uploads) { upload in
                    uploadRow(upload)
                }

                Text("支持的文件优先尝试 App 内下载；第三方镜像无法直接下载时会打开原网站。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            } else if isLoading {
                ProgressView("正在查找下载选项…")
                    .foregroundStyle(.secondary)

            } else {
                Text("没有识别到下载选项。游戏可能需要登录、购买，或下载页面暂时无法访问。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uploadRow(_ upload: GameUpload) -> some View {
        Group {
            if let localURL = downloadedFiles[upload.id] {
                ShareLink(item: localURL) {
                    uploadRowLabel(
                        upload,
                        subtitle: "已下载 · 分享或存储文件",
                        trailingIcon: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.plain)

            } else {
                Button {
                    if upload.isDirectDownload {
                        Task {
                            await downloadFile(upload)
                        }
                    } else {
                        openURL(upload.url)
                    }
                } label: {
                    uploadRowLabel(
                        upload,
                        subtitle: upload.isDirectDownload
                            ? "App 内下载 · \(upload.provider)"
                            : "打开 \(upload.provider) 下载页",
                        trailingIcon: upload.isDirectDownload
                            ? "arrow.down.circle"
                            : "arrow.up.right"
                    )
                }
                .buttonStyle(.plain)
                .disabled(downloadingIDs.contains(upload.id))
            }
        }
    }

    private func uploadRowLabel(
        _ upload: GameUpload,
        subtitle: String,
        trailingIcon: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(
                systemName: upload.isDirectDownload
                    ? fileIcon(for: upload.name)
                    : "link"
            )
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text(upload.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(subtitle)

                    if let size = upload.fileSize,
                       !size.isEmpty {
                        Text("·")
                        Text(size)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if downloadingIDs.contains(upload.id) {
                ProgressView()
            } else {
                Image(systemName: trailingIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Download

    @MainActor
    private func downloadFile(_ upload: GameUpload) async {
        downloadingIDs.insert(upload.id)

        defer {
            downloadingIDs.remove(upload.id)
        }

        do {
            var request = URLRequest(url: upload.url)
            request.timeoutInterval = 180
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )

            let (temporaryURL, response) =
                try await URLSession.shared.download(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            let suggestedName =
                response.suggestedFilename
                ?? upload.url.lastPathComponent.removingPercentEncoding
                ?? upload.name

            let safeName = suggestedName
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")

            let folder = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "Downloads",
                isDirectory: true
            )

            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let destination = folder.appendingPathComponent(
                safeName.isEmpty ? "downloaded-file" : safeName
            )

            if FileManager.default.fileExists(
                atPath: destination.path
            ) {
                try FileManager.default.removeItem(
                    at: destination
                )
            }

            try FileManager.default.moveItem(
                at: temporaryURL,
                to: destination
            )

            downloadedFiles[upload.id] = destination

            downloadMessage =
                "文件已下载到 itchPocket。点击该文件选项，可以通过分享面板保存到 iPhone 的“文件”App。"

            showingDownloadMessage = true

        } catch {
            downloadMessage =
                "App 内下载失败：\(error.localizedDescription)\n\n将尝试打开原下载地址。"

            showingDownloadMessage = true
            openURL(upload.url)
        }
    }

    private func fileIcon(for name: String) -> String {
        let value = name.lowercased()

        if [
            ".zip", ".7z", ".rar", ".tar", ".gz"
        ].contains(where: value.hasSuffix) {
            return "doc.zipper"
        }

        if [
            ".dmg", ".pkg", ".exe", ".app", ".msi"
        ].contains(where: value.hasSuffix) {
            return "desktopcomputer"
        }

        if value.hasSuffix(".pdf") {
            return "doc.richtext"
        }

        return "doc"
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
        isLoading = false
        errorMessage = nil
    }

    private func handleLoadError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    private func reloadDetail() {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil
        detail = nil
        downloadedFiles = [:]
        reloadToken = UUID()
    }
}

// MARK: - Two Stage Web Reader

private struct DetailPageReader: UIViewRepresentable {
    let url: URL?
    let reloadToken: UUID

    let onLoad: (GameDetailPayload) -> Void
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

        guard let url else {
            DispatchQueue.main.async {
                context.coordinator.parent.onError(
                    "游戏页面地址无效。"
                )
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
        context.coordinator.stage = .game
        context.coordinator.gamePayload = nil

        guard let url else {
            onError("游戏页面地址无效。")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        request.cachePolicy = .reloadIgnoringLocalCacheData

        webView.load(request)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        enum Stage {
            case game
            case download
        }

        var parent: DetailPageReader
        var currentToken: UUID?

        var stage: Stage = .game
        var gamePayload: GamePagePayload?

        private var extractionID = UUID()

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            let id = UUID()
            extractionID = id

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.8
            ) {
                guard self.extractionID == id else {
                    return
                }

                switch self.stage {
                case .game:
                    self.extractGamePage(
                        in: webView,
                        id: id
                    )

                case .download:
                    self.extractDownloadPage(
                        in: webView,
                        id: id
                    )
                }
            }
        }

        // MARK: First Stage

        private func extractGamePage(
            in webView: WKWebView,
            id: UUID
        ) {
            webView.evaluateJavaScript(
                Self.gamePageScript
            ) { result, error in

                guard self.extractionID == id else {
                    return
                }

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
                    self.fail("游戏主页没有返回可识别的数据。")
                    return
                }

                self.gamePayload = payload

                guard let downloadURL = payload.downloadURL else {
                    self.finishWithoutDownloadPage()
                    return
                }

                self.stage = .download

                var request = URLRequest(url: downloadURL)
                request.timeoutInterval = 40
                request.cachePolicy = .reloadIgnoringLocalCacheData

                webView.load(request)
            }
        }

        // MARK: Second Stage

        private func extractDownloadPage(
            in webView: WKWebView,
            id: UUID
        ) {
            webView.evaluateJavaScript(
                Self.downloadPageScript
            ) { result, error in

                guard self.extractionID == id else {
                    return
                }

                if let error {
                    self.finishWithError(
                        "读取下载选项失败：\(error.localizedDescription)"
                    )
                    return
                }

                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(
                        DownloadPagePayload.self,
                        from: data
                      ) else {
                    self.finishWithError(
                        "下载页面没有返回有效的选项数据。"
                    )
                    return
                }

                let uploads = parsed.uploads.map {
                    GameUpload(
                        id: $0.id,
                        name: $0.name,
                        url: $0.url,
                        fileSize: $0.fileSize,
                        provider: $0.provider,
                        isDirectDownload: $0.isDirectDownload
                    )
                }

                let metadata = self.gamePayload

                DispatchQueue.main.async {
                    self.parent.onLoad(
                        GameDetailPayload(
                            description: metadata?.description,
                            developer: metadata?.developer,
                            coverURL: metadata?.coverURL,
                            uploads: uploads
                        )
                    )
                }
            }
        }

        private func finishWithoutDownloadPage() {
            let metadata = gamePayload

            DispatchQueue.main.async {
                self.parent.onLoad(
                    GameDetailPayload(
                        description: metadata?.description,
                        developer: metadata?.developer,
                        coverURL: metadata?.coverURL,
                        uploads: []
                    )
                )
            }
        }

        private func finishWithError(_ message: String) {
            let metadata = gamePayload

            DispatchQueue.main.async {
                self.parent.onLoad(
                    GameDetailPayload(
                        description: metadata?.description,
                        developer: metadata?.developer,
                        coverURL: metadata?.coverURL,
                        uploads: []
                    )
                )

                self.parent.onError(message)
            }
        }

        private func fail(_ message: String) {
            DispatchQueue.main.async {
                self.parent.onError(message)
            }
        }

        // MARK: Navigation Errors

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

            if stage == .download {
                finishWithError(
                    "无法打开 itch.io 下载页面：\(error.localizedDescription)"
                )
            } else {
                fail(
                    "无法打开 itch.io 游戏页面：\(error.localizedDescription)"
                )
            }
        }

        // MARK: JavaScript

        private static let gamePageScript = """
        (() => {
            const clean = el => (
                el?.innerText ||
                el?.textContent ||
                ""
            ).replace(/\\\\s+/g, " ").trim();

            const absolute = value => {
                try {
                    return value
                        ? new URL(value, location.href).href
                        : null;
                } catch (_) {
                    return null;
                }
            };

            // Description

            let description = null;

            for (const selector of [
                ".formatted_description",
                ".game_page_content .formatted_description",
                ".game_description",
                "#game_description"
            ]) {
                const el = document.querySelector(selector);
                const value = clean(el);

                if (value.length > 20) {
                    description = value;
                    break;
                }
            }

            if (!description) {
                description =
                    document.querySelector(
                        'meta[name="description"]'
                    )?.getAttribute("content") || null;
            }

            // Developer

            let developer = null;

            for (const selector of [
                ".game_author a",
                ".game_author",
                ".header_links .user_link",
                ".user_link"
            ]) {
                const value = clean(
                    document.querySelector(selector)
                );

                if (value) {
                    developer = value;
                    break;
                }
            }

            // Cover

            let coverURL = null;

            for (const selector of [
                'meta[property="og:image"]',
                'meta[name="twitter:image"]',
                ".game_cover img",
                ".game_thumb img",
                ".screenshot img"
            ]) {
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

            // Download page link

            const links = Array.from(
                document.querySelectorAll("a[href]")
            );

            let downloadLink = links.find(a => {
                const href = absolute(
                    a.getAttribute("href")
                );

                if (!href) return false;

                let path = "";

                try {
                    path = new URL(href).pathname;
                } catch (_) {
                    return false;
                }

                return /\\\\/download\\\\//i.test(path);
            });

            if (!downloadLink) {
                downloadLink = document.querySelector(
                    'a[href*="/download/"]'
                );
            }

            return JSON.stringify({
                description,
                developer,
                coverURL,
                downloadURL: downloadLink
                    ? absolute(
                        downloadLink.getAttribute("href")
                    )
                    : null
            });
        })();
        """

        private static let downloadPageScript = """
        (() => {
            const clean = el => (
                el?.innerText ||
                el?.textContent ||
                ""
            ).replace(/\\\\s+/g, " ").trim();

            const absolute = value => {
                try {
                    return value
                        ? new URL(value, location.href).href
                        : null;
                } catch (_) {
                    return null;
                }
            };

            const providerName = url => {
                const host = new URL(url)
                    .hostname
                    .toLowerCase()
                    .replace(/^www\\\\./, "");

                if (host.includes("mediafire")) return "MediaFire";
                if (host.includes("pixeldrain")) return "PixelDrain";
                if (host.includes("transfer.it")) return "Transfer.it";
                if (host.includes("mega.nz") || host.includes("mega.co.nz")) return "MEGA";
                if (host.includes("drive.google")) return "Google Drive";
                if (host.includes("dropbox")) return "Dropbox";
                if (host.includes("gofile")) return "Gofile";
                if (host.includes("itch.io")) return "itch.io";

                return host;
            };

            const directExtension =
                /\\\\.(zip|7z|rar|tar|gz|dmg|pkg|exe|msi|apk|pdf|iso)(?:$|[?#])/i;

            const containers = Array.from(
                document.querySelectorAll(
                    '#download, .download, .download_links, ' +
                    '.download_list, .game_download, .upload, ' +
                    '.download_link, main, .game_page'
                )
            );

            let anchors = [];

            for (const container of containers) {
                anchors.push(
                    ...container.querySelectorAll("a[href]")
                );
            }

            if (anchors.length === 0) {
                anchors = Array.from(
                    document.querySelectorAll("a[href]")
                );
            }

            const results = [];
            const seen = new Set();

            for (const a of anchors) {
                const href = absolute(
                    a.getAttribute("href")
                );

                if (!href || seen.has(href)) continue;

                let parsed;

                try {
                    parsed = new URL(href);
                } catch (_) {
                    continue;
                }

                const host = parsed.hostname.toLowerCase();

                const isItchHost =
                    host === "itch.io" ||
                    host.endsWith(".itch.io");

                const path = parsed.pathname.toLowerCase();

                if (/^(javascript:|mailto:|#)/i.test(href)) {
                    continue;
                }

                const parent = a.closest(
                    '.upload, .download_link, .download, ' +
                    '.download_item, li, .button'
                ) || a.parentElement;

                const parentText = clean(parent);
                const anchorText =
                    clean(a) ||
                    a.getAttribute("aria-label") ||
                    a.getAttribute("title") ||
                    "";

                const provider = providerName(href);

                // Ignore unrelated itch navigation links.
                if (
                    isItchHost &&
                    !path.includes("/file/") &&
                    !path.includes("/download/")
                ) {
                    continue;
                }

                // For external sites, accept recognizable mirror
                // providers or links located in download containers.
                const knownProvider = [
                    "MediaFire",
                    "PixelDrain",
                    "Transfer.it",
                    "MEGA",
                    "Google Drive",
                    "Dropbox",
                    "Gofile"
                ].includes(provider);

                const downloadContext =
                    /download|mirror|file|下载|镜像/i.test(
                        anchorText + " " + parentText
                    );

                if (
                    !isItchHost &&
                    !knownProvider &&
                    !downloadContext
                ) {
                    continue;
                }

                const name =
                    anchorText ||
                    provider;

                if (
                    !name ||
                    /^(home|community|devlog|itch.io)$/i.test(name)
                ) {
                    continue;
                }

                const sizeMatch = parentText.match(
                    /\\\\b\\\\d+(?:\\\\.\\\\d+)?\\\\s*(?:KB|MB|GB|TB)\\\\b/i
                );

                const isDirect =
                    directExtension.test(href) ||
                    (
                        isItchHost &&
                        path.includes("/file/")
                    );

                seen.add(href);

                results.push({
                    id: href,
                    name: name.slice(0, 120),
                    url: href,
                    fileSize: sizeMatch
                        ? sizeMatch[0]
                        : null,
                    provider,
                    isDirectDownload: isDirect
                });
            }

            return JSON.stringify({
                uploads: results
            });
        })();
        """
    }
}
