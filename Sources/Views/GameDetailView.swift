
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
}

// MARK: - Game Detail View

struct GameDetailView: View {
    let game: PublicCollectionGame

    @Environment(\.openURL) private var openURL
    @State private var detail: GameDetailPayload?
    @State private var isLoading = true
    @State private var errorMessage: String?

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

                VStack(alignment: .leading, spacing: 9) {
                    Text(game.title)
                        .font(.largeTitle.bold())

                    if let developer = displayDeveloper,
                       !developer.isEmpty {
                        Text(developer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !game.platforms.isEmpty {
                        Text(game.platforms.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                descriptionSection

                uploadsSection

                if let url = game.url {
                    Button {
                        openURL(url)
                    } label: {
                        Label(
                            "在 itch.io 查看游戏页面",
                            systemImage: "safari"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            DetailPageReader(
                url: game.url,
                onLoad: { result in
                    detail = result
                    isLoading = false
                    errorMessage = nil
                },
                onError: { message in
                    isLoading = false
                    errorMessage = message
                }
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
            } else if isLoading {
                ProgressView("正在读取游戏介绍…")
                    .foregroundStyle(.secondary)
            } else {
                Text("暂时无法读取游戏介绍，请前往 itch.io 查看完整内容。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Uploads

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下载文件")
                .font(.title2.bold())

            if isLoading && detail == nil {
                ProgressView("正在读取下载文件…")
                    .foregroundStyle(.secondary)

            } else if let uploads = detail?.uploads,
                      !uploads.isEmpty {
                ForEach(uploads) { upload in
                    Button {
                        openURL(upload.url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipped")
                                .font(.title2)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(upload.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)

                                Text("在 itch.io 打开文件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(13)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                    }
                    .buttonStyle(.plain)
                }

            } else {
                Text(
                    errorMessage ??
                    "暂时没有识别到公开下载文件。部分游戏需要登录或购买后才能下载。"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hidden Web Page Reader

private struct DetailPageReader: UIViewRepresentable {
    let url: URL?
    let onLoad: (GameDetailPayload) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        if let url {
            webView.load(URLRequest(url: url))
        } else {
            DispatchQueue.main.async {
                context.coordinator.parent.onError("游戏页面地址无效。")
            }
        }

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DetailPageReader

        init(parent: DetailPageReader) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            webView.evaluateJavaScript(Self.script) {
                result, error in

                if let error {
                    DispatchQueue.main.async {
                        self.parent.onError(
                            error.localizedDescription
                        )
                    }
                    return
                }

                guard let json = result as? String,
                      let data = json.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        self.parent.onError("没有读取到有效的游戏详情。")
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
                            "游戏详情解析失败：\(error.localizedDescription)"
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
            DispatchQueue.main.async {
                self.parent.onError(error.localizedDescription)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.parent.onError(error.localizedDescription)
            }
        }

        private static let script = """
        (() => {
            const text = (element) => {
                if (!element) return "";
                return (element.innerText || element.textContent || "")
                    .replace(/\\\\s+/g, " ")
                    .trim();
            };

            const absolute = (value) => {
                if (!value) return null;
                try {
                    return new URL(value, location.href).href;
                } catch (_) {
                    return null;
                }
            };

            const descriptionElement = document.querySelector(
                ".formatted_description, .game_page_content .formatted_description, .game_description"
            );

            const developerElement = document.querySelector(
                ".game_author a, .game_author, .header_links a"
            );

            const imageElement = document.querySelector(
                ".game_cover img, .screenshot img, meta[property='og:image']"
            );

            let cover = null;

            if (imageElement) {
                cover = imageElement.getAttribute("content") ||
                        imageElement.currentSrc ||
                        imageElement.getAttribute("src");

                cover = absolute(cover);
            }

            const uploads = [];
            const seen = new Set();

            const links = Array.from(
                document.querySelectorAll(
                    "a[href*='/download/'], .upload a[href]"
                )
            );

            for (const link of links) {
                const href = absolute(link.getAttribute("href"));
                if (!href || seen.has(href)) continue;

                seen.add(href);

                const container = link.closest(".upload");
                const name =
                    text(container?.querySelector(".name")) ||
                    text(link) ||
                    "下载文件";

                uploads.push({
                    id: href,
                    name: name,
                    url: href
                });
            }

            return JSON.stringify({
                description: text(descriptionElement) || null,
                developer: text(developerElement) || null,
                coverURL: cover,
                uploads: uploads
            });
        })();
        """
    }
}
