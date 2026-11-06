
import SwiftUI
import WebKit

// MARK: - Detail Models

private struct GameDetailPayload: Decodable {
    let description: String?
    let developer: String?
    let coverURL: URL?
    let uploads: [GameUpload]
}

private struct GameUpload: Decodable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let fileSize: String?
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let game: PublicCollectionGame

    @Environment(\.openURL) private var openURL

    @State private var detail: GameDetailPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

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
                .accessibilityLabel("重新读取游戏详情")
            }
        }
        .background {
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

    // MARK: - Cover

    private var coverSection: some View {
        Group {
            if let url = displayCover {
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
        .frame(maxWidth: .infinity)
        .aspectRatio(1.45, contentMode: .fit)
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

    // MARK: - Title

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

    // MARK: - Description

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
    }

    // MARK: - Uploads

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("下载文件")
                    .font(.title2.bold())

                Spacer()

                if let uploads = detail?.uploads,
                   !uploads.isEmpty {
                    Text("\(uploads.count) 个文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && detail == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取下载文件…")
                        .foregroundStyle(.secondary)
                }

            } else if let uploads = detail?.uploads,
                      !uploads.isEmpty {
                ForEach(uploads) { upload in
                    uploadRow(upload)
                }

            } else if isLoading {
                ProgressView("正在查找下载文件…")
                    .foregroundStyle(.secondary)

            } else {
                Text(
                    "暂时没有识别到公开下载文件。部分游戏可能需要登录、购买或满足开发者设置的条件才能下载。"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func uploadRow(_ upload: GameUpload) -> some View {
        Button {
            openURL(upload.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: fileIcon(for: upload.name))
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 5) {
                    Text(upload.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text("itch.io 下载入口")

                        if let fileSize = upload.fileSize,
                           !fileSize.isEmpty {
                            Text("·")
                            Text(fileSize)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func fileIcon(for name: String) -> String {
        let value = name.lowercased()

        if value.hasSuffix(".zip")
            || value.hasSuffix(".7z")
            || value.hasSuffix(".rar") {
            return "doc.zipper"
        }

        if value.hasSuffix(".dmg")
            || value.hasSuffix(".pkg")
            || value.hasSuffix(".exe")
            || value.hasSuffix(".app") {
            return "desktopcomputer"
        }

        if value.hasSuffix(".pdf") {
            return "doc.richtext"
        }

        return "doc"
    }

    // MARK: - Error

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

            Button("重新读取") {
                reloadDetail()
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: - Original Page

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

    // MARK: - Data Handling

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
        reloadToken = UUID()
    }
}

// MARK: - Hidden Web Page Reader

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
        request.timeoutInterval = 30
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

        guard let url else {
            onError("游戏页面地址无效。")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        webView.load(request)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DetailPageReader
        var currentToken: UUID?

        private var extractionID = UUID()

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            let currentExtractionID = UUID()
            extractionID = currentExtractionID

            // 等待页面中的延迟内容和图片信息完成初始化
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard self.extractionID == currentExtractionID else {
                    return
                }

                webView.evaluateJavaScript(
                    Self.extractionScript
                ) { result, error in

                    guard self.extractionID == currentExtractionID else {
                        return
                    }

                    if let error {
                        DispatchQueue.main.async {
                            self.parent.onError(
                                "解析游戏页面失败：\(error.localizedDescription)"
                            )
                        }
                        return
                    }

                    guard let json = result as? String,
                          let data = json.data(using: .utf8) else {
                        DispatchQueue.main.async {
                            self.parent.onError(
                                "游戏页面没有返回有效的数据。"
                            )
                        }
                        return
                    }

                    do {
                        let payload = try JSONDecoder().decode(
                            GameDetailPayload.self,
                            from: data
                        )

                        DispatchQueue.main.async {
                            self.parent.onLoad(payload)
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
                    "无法打开 itch.io 游戏页面：\(error.localizedDescription)"
                )
            }
        }

        // MARK: - JavaScript Extraction

        private static let extractionScript = """
        (() => {
            const cleanText = (element) => {
                if (!element) return "";

                return (
                    element.innerText ||
                    element.textContent ||
                    ""
                )
                .replace(/\\\\s+/g, " ")
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

            // MARK: Description

            const descriptionSelectors = [
                ".formatted_description",
                ".game_page_content .formatted_description",
                ".game_description",
                ".game_page_content",
                "#game_description"
            ];

            let description = null;

            for (const selector of descriptionSelectors) {
                const element = document.querySelector(selector);

                if (element) {
                    const value = cleanText(element);

                    if (value.length > 20) {
                        description = value;
                        break;
                    }
                }
            }

            if (!description) {
                const metaDescription = document.querySelector(
                    'meta[name="description"]'
                );

                description = metaDescription
                    ? metaDescription.getAttribute("content")
                    : null;
            }

            // MARK: Developer

            const developerSelectors = [
                ".game_author a",
                ".game_author",
                ".header_links .user_link",
                ".user_link"
            ];

            let developer = null;

            for (const selector of developerSelectors) {
                const element = document.querySelector(selector);
                const value = cleanText(element);

                if (value) {
                    developer = value;
                    break;
                }
            }

            // MARK: Cover

            let cover = null;

            const coverSelectors = [
                'meta[property="og:image"]',
                'meta[name="twitter:image"]',
                ".game_cover img",
                ".game_thumb img",
                ".screenshot img"
            ];

            for (const selector of coverSelectors) {
                const element = document.querySelector(selector);

                if (!element) continue;

                let value =
                    element.getAttribute("content") ||
                    element.currentSrc ||
                    element.getAttribute("data-lazy_src") ||
                    element.getAttribute("data-lazy-src") ||
                    element.getAttribute("data-src") ||
                    element.getAttribute("src");

                value = absoluteURL(value);

                if (value) {
                    cover = value;
                    break;
                }
            }

            // MARK: Uploads

            const uploads = [];
            const seen = new Set();

            const uploadContainers = Array.from(
                document.querySelectorAll(
                    ".upload, .upload_list .upload, #download .upload"
                )
            );

            const addUpload = (link, container) => {
                const href = absoluteURL(
                    link.getAttribute("href")
                );

                if (!href || seen.has(href)) return;

                let parsedURL;

                try {
                    parsedURL = new URL(href);
                } catch (_) {
                    return;
                }

                // 只保留 itch.io 下载入口，排除无关外链
                const isItchHost =
                    parsedURL.hostname === "itch.io" ||
                    parsedURL.hostname.endsWith(".itch.io");

                const isDownloadPath =
                    parsedURL.pathname.includes("/download/");

                if (!isItchHost || !isDownloadPath) return;

                seen.add(href);

                const nameElement =
                    container?.querySelector(
                        ".upload_name, .name, .upload_title, h3, h4"
                    );

                let name =
                    cleanText(nameElement) ||
                    cleanText(link);

                if (!name || name.toLowerCase() === "download") {
                    name = "游戏文件";
                }

                const sizeElement =
                    container?.querySelector(
                        ".upload_info, .file_size, .size"
                    );

                let fileSize = cleanText(sizeElement);

                if (!fileSize) {
                    const text = cleanText(container);
                    const match = text.match(
                        /\\\\b\\\\d+(?:\\\\.\\\\d+)?\\\\s*(?:KB|MB|GB|TB)\\\\b/i
                    );

                    fileSize = match ? match[0] : null;
                }

                uploads.push({
                    id: href,
                    name: name,
                    url: href,
                    fileSize: fileSize || null
                });
            };

            // 优先读取每个上传文件的独立容器
            for (const container of uploadContainers) {
                const links = Array.from(
                    container.querySelectorAll("a[href]")
                );

                for (const link of links) {
                    addUpload(link, container);
                }
            }

            // 补充读取下载区域中未被容器覆盖的入口
            const downloadArea = document.querySelector(
                "#download, .game_download, .uploads"
            );

            if (downloadArea) {
                const links = Array.from(
                    downloadArea.querySelectorAll("a[href]")
                );

                for (const link of links) {
                    addUpload(
                        link,
                        link.closest(".upload") || downloadArea
                    );
                }
            }

            return JSON.stringify({
                description: description || null,
                developer: developer || null,
                coverURL: cover,
                uploads: uploads
            });
        })();
        """
    }
}
