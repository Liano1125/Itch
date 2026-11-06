import SwiftUI
import WebKit

struct DiscoverView: View {
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

            Text("发现好玩的\n独立游戏。")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)

            Text("从 itch.io 探索那些值得收藏的作品")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                    Text("打开 itch.io 的精选作品")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("浏览分类")
                .font(.title3.bold())

            VStack(spacing: 10) {
                browseRow(
                    title: "全部游戏",
                    subtitle: "探索 itch.io 的完整游戏目录",
                    symbol: "square.grid.2x2.fill",
                    tint: .blue,
                    url: "https://itch.io/games"
                )

                browseRow(
                    title: "免费游戏",
                    subtitle: "发现可以免费体验的作品",
                    symbol: "gift.fill",
                    tint: .green,
                    url: "https://itch.io/games/price-free"
                )

                browseRow(
                    title: "即将结束的 Game Jam",
                    subtitle: "看看独立开发者正在参与的创作活动",
                    symbol: "timer",
                    tint: .orange,
                    url: "https://itch.io/jams"
                )
            }
        }
    }

    private func browseRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        url: String
    ) -> some View {
        NavigationLink {
            ItchSearchResultsView(query: "", customURL: url)
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

    var body: some View {
        ItchWebView(url: searchURL)
            .navigationTitle(query.isEmpty ? "浏览 itch.io" : query)
            .navigationBarTitleDisplayMode(.inline)
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

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
