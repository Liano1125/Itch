
import SwiftUI
import WebKit
import Foundation

// MARK: - Models

private struct GamePagePayload: Decodable {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let uploads: [UploadItem]
    let pageURL: String?
    let pageTitle: String?
    let totalAnchors: Int
    let scriptError: String?
    
    struct UploadItem: Decodable {
        let id: String
        let name: String
        let url: URL
        let fileSize: String?
        let provider: String
        let isDirectDownload: Bool
    }
}

private struct GameDetailPayload {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let uploads: [GameUpload]
    let diagnostic: String?
}

private struct GameUpload: Identifiable {
    let id: String
    let name: String
    let url: URL
    let fileSize: String?
    let provider: String
    let isDirectDownload: Bool
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
                Label(developer, systemImage: "person")
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
                    Text("正在扫描游戏页面…")
                        .foregroundStyle(.secondary)
                }

            } else if let uploads = detail?.uploads,
                      !uploads.isEmpty {
                ForEach(uploads) { upload in
                    uploadRow(upload)
                }

                Text("支持的文件优先尝试 App 内下载；第三方镜像会打开对应下载网站。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

            } else {
                Text("没有识别到下载选项。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let diagnostic = detail?.diagnostic {
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
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
        ].contains(where: { value.hasSuffix($0) }) {
            return "doc.zipper"
        }

        if [
            ".dmg", ".pkg", ".exe", ".app", ".msi"
        ].contains(where: { value.hasSuffix($0) }) {
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

// MARK: - Web Reader

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
        request.timeoutInterval = 50
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
        context.coordinator.extractionID = UUID()

        guard let url else {
            onError("游戏页面地址无效。")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 50
        request.cachePolicy = .reloadIgnoringLocalCacheData

        webView.load(request)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DetailPageReader
        var currentToken: UUID?
        var extractionID = UUID()

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            let id = UUID()
            extractionID = id

            // 等待页面脚本及动态内容完成。
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.5
            ) {
                guard self.extractionID == id else {
                    return
                }

                self.extractPage(
                    in: webView,
                    id: id
                )
            }
        }

        // MARK: Extract Page

        private func extractPage(
            in webView: WKWebView,
            id: UUID
        ) {
            webView.evaluateJavaScript(
                Self.pageExtractionScript
            ) { result, error in

                guard self.extractionID == id else {
                    return
                }

                if let error {
                    self.fail(
                        "页面解析异常：\(error.localizedDescription)"
                    )
                    return
                }

                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(
                        GamePagePayload.self,
                        from: data
                      ) else {
                    self.fail(
                        "页面数据无法解析。请重新读取。"
                    )
                    return
                }

                if let scriptError = payload.scriptError {
                    self.fail(
                        "JavaScript 异常：\(scriptError)"
                    )
                    return
                }

                let uploads = payload.uploads.map {
                    GameUpload(
                        id: $0.id,
                        name: $0.name,
                        url: $0.url,
                        fileSize: $0.fileSize,
                        provider: $0.provider,
                        isDirectDownload: $0.isDirectDownload
                    )
                }

                let diagnostic =
                    "页面标题：\(payload.pageTitle ?? "未知")\n" +
                    "当前网址：\(payload.pageURL ?? "未知")\n" +
                    "扫描到的链接：\(payload.totalAnchors)\n" +
                    "识别到的下载选项：\(uploads.count)"

                let detail = GameDetailPayload(
                    description: payload.description,
                    developer: payload.developer,
                    coverURL: payload.coverURL,
                    uploads: uploads,
                    diagnostic: diagnostic
                )

                DispatchQueue.main.async {
                    self.parent.onLoad(detail)
                }
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
            report(error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error, webView: webView)
        }

        private func report(
            _ error: Error,
            webView: WKWebView
        ) {
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }

            let message =
                "网页加载失败：\(error.localizedDescription)\n" +
                "当前网址：\(webView.url?.absoluteString ?? "未知")"

            fail(message)
        }

        // MARK: JavaScript

        private static let pageExtractionScript = """
        (() => {
            try {
                const clean = el => {
                    const value = el?.innerText ||
                                  el?.textContent || "";

                    return value
                        .replace(/\\s+/g, " ")
                        .trim();
                };

                const absolute = value => {
                    try {
                        return value
                            ? new URL(value, location.href).href
                            : null;
                    } catch (_) {
                        return null;
                    }
                };

                // -------------------------
                // Game description
                // -------------------------

                let description = null;

                const descriptionSelectors = [
                    ".formatted_description",
                    ".game_page_content .formatted_description",
                    ".game_description",
                    "#game_description"
                ];

                for (const selector of descriptionSelectors) {
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

                // -------------------------
                // Developer
                // -------------------------

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

                // -------------------------
                // Cover
                // -------------------------

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
                        el.getAttribute("data-src") ||
                        el.getAttribute("src")
                    );

                    if (value) {
                        coverURL = value;
                        break;
                    }
                }

                // -------------------------
                // Provider detection
                // -------------------------

                const providerName = url => {
                    let host = "";

                    try {
                        host = new URL(url).hostname.toLowerCase();
                    } catch (_) {
                        return "";
                    }

                    if (host.includes("mediafire")) {
                        return "MediaFire";
                    }

                    if (host.includes("pixeldrain")) {
                        return "PixelDrain";
                    }

                    if (
                        host.includes("transfer.it") ||
                        host.includes("transfernow")
                    ) {
                        return "Transfer.it";
                    }

                    if (
                        host.includes("mega.nz") ||
                        host.includes("mega.co.nz")
                    ) {
                        return "MEGA";
                    }

                    if (host.includes("drive.google")) {
                        return "Google Drive";
                    }

                    if (host.includes("dropbox")) {
                        return "Dropbox";
                    }

                    if (host.includes("gofile")) {
                        return "Gofile";
                    }

                    if (host.includes("1fichier")) {
                        return "1fichier";
                    }

                    if (host.includes("pixeldrain")) {
                        return "PixelDrain";
                    }

                    if (host.includes("itch.io")) {
                        return "itch.io";
                    }

                    return host;
                };

                const knownProviders = [
                    "MediaFire",
                    "PixelDrain",
                    "Transfer.it",
                    "MEGA",
                    "Google Drive",
                    "Dropbox",
                    "Gofile",
                    "1fichier"
                ];

                // -------------------------
                // Download candidates
                // -------------------------

                const allNodes = Array.from(
                    document.querySelectorAll(
                        'a[href], ' +
                        '[data-href], ' +
                        '[data-url], ' +
                        '[data-download-url]'
                    )
                );

                const results = [];
                const seen = new Set();

                const fileContainers = [
                    ".upload",
                    ".uploads",
                    ".upload_list",
                    ".file",
                    ".files",
                    ".file_list",
                    ".game_files",
                    ".download",
                    ".downloads",
                    ".download_link",
                    ".download_links",
                    ".download_list",
                    ".post_file",
                    ".post_files",
                    ".formatted_description",
                    ".game_page_content",
                    ".game_page",
                    "main"
                ];

                for (const node of allNodes) {
                    const rawURL =
                        node.getAttribute("href") ||
                        node.getAttribute("data-download-url") ||
                        node.getAttribute("data-href") ||
                        node.getAttribute("data-url");

                    const href = absolute(rawURL);

                    if (!href || seen.has(href)) {
                        continue;
                    }

                    let parsed;

                    try {
                        parsed = new URL(href);
                    } catch (_) {
                        continue;
                    }

                    if (
                        parsed.protocol !== "http:" &&
                        parsed.protocol !== "https:"
                    ) {
                        continue;
                    }

                    const host = parsed.hostname.toLowerCase();
                    const path = parsed.pathname.toLowerCase();

                    const isItchHost =
                        host === "itch.io" ||
                        host.endsWith(".itch.io");

                    const provider = providerName(href);

                    const anchorText =
                        clean(node) ||
                        node.getAttribute("aria-label") ||
                        node.getAttribute("title") ||
                        "";

                    let container = node.closest(
                        fileContainers.join(",")
                    );

                    if (!container) {
                        container = node.parentElement;
                    }

                    const containerText = clean(container);

                    const combinedText = (
                        anchorText + " " + containerText
                    ).toLowerCase();

                    const hasKnownProvider =
                        knownProviders.includes(provider);

                    const hasDownloadWords =
                        combinedText.includes("download") ||
                        combinedText.includes("mirror") ||
                        combinedText.includes("file") ||
                        combinedText.includes("下载") ||
                        combinedText.includes("镜像");

                    const isDownloadPath =
                        path.includes("/download/") ||
                        path.endsWith("/download") ||
                        path.includes("/file/");

                    // Ignore ordinary itch.io navigation.
                    if (
                        isItchHost &&
                        !isDownloadPath
                    ) {
                        continue;
                    }

                    // Keep external links when they are known mirrors,
                    // or when their surrounding element looks like a file.
                    if (
                        !isItchHost &&
                        !hasKnownProvider &&
                        !hasDownloadWords
                    ) {
                        continue;
                    }

                    const name =
                        anchorText ||
                        provider ||
                        "下载文件";

                    if (!name) {
                        continue;
                    }

                    const lowerName = name.toLowerCase();

                    if (
                        lowerName === "home" ||
                        lowerName === "community" ||
                        lowerName === "devlog" ||
                        lowerName === "itch.io"
                    ) {
                        continue;
                    }

                    // Determine whether the URL appears to be
                    // an actual file URL.
                    const lastPart =
                        path.split("/").pop() || "";

                    const extensionIndex =
                        lastPart.lastIndexOf(".");

                    const extension = extensionIndex >= 0
                        ? lastPart.substring(extensionIndex + 1)
                        : "";

                    const directExtensions = [
                        "zip", "7z", "rar", "tar", "gz",
                        "dmg", "pkg", "exe", "msi",
                        "apk", "pdf", "iso"
                    ];

                    const isDirect =
                        directExtensions.includes(extension) ||
                        (
                            isItchHost &&
                            path.includes("/file/")
                        );

                    seen.add(href);

                    results.push({
                        id: href,
                        name: name.substring(0, 160),
                        url: href,
                        fileSize: null,
                        provider: provider || "下载网站",
                        isDirectDownload: isDirect
                    });
                }

                // -------------------------
                // Diagnostics
                // -------------------------

                return JSON.stringify({
                    description,
                    developer,
                    coverURL,
                    uploads: results,
                    pageURL: location.href,
                    pageTitle: document.title,
                    totalAnchors: allNodes.length,
                    scriptError: null
                });

            } catch (error) {
                return JSON.stringify({
                    description: null,
                    developer: null,
                    coverURL: null,
                    uploads: [],
                    pageURL: location.href,
                    pageTitle: document.title,
                    totalAnchors: 0,
                    scriptError: String(error)
                });
            }
        })();
        """
    }
}
