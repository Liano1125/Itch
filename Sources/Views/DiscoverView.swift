
import SwiftUI
import WebKit

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var submittedQuery = ""
    @State private var showSearchResults = false

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("发现游戏")
                            .font(.largeTitle.bold())

                        Text("探索 itch.io 上的独立游戏")
                            .foregroundStyle(.secondary)
                    }

                    searchBar

                    Button {
                        performSearch()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                            Text("搜索游戏")
                            Spacer()
                        }
                        .font(.headline)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedSearchText.isEmpty)

                    VStack(alignment: .leading, spacing: 15) {
                        Text("浏览 itch.io")
                            .font(.headline)

                        browseLink(
                            "浏览全部游戏",
                            icon: "gamecontroller",
                            url: "https://itch.io/games"
                        )

                        browseLink(
                            "精选游戏",
                            icon: "star",
                            url: "https://itch.io/games/featured"
                        )

                        browseLink(
                            "免费游戏",
                            icon: "gift",
                            url: "https://itch.io/games/price-free"
                        )
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(
                isPresented: $showSearchResults
            ) {
                ItchSearchResultsView(
                    query: submittedQuery
                )
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "搜索游戏或开发者",
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                performSearch()
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(15)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 17)
        )
    }

    private func performSearch() {
        guard !trimmedSearchText.isEmpty else {
            return
        }

        submittedQuery = trimmedSearchText
        showSearchResults = true
    }

    private func browseLink(
        _ title: String,
        icon: String,
        url: String
    ) -> some View {
        NavigationLink {
            ItchSearchResultsView(
                query: "",
                customURL: url
            )
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
        }
    }
}

// MARK: - In-App Search Results

struct ItchSearchResultsView: View {
    let query: String
    var customURL: String? = nil

    var body: some View {
        ItchWebView(
            url: searchURL
        )
        .navigationTitle(
            query.isEmpty ? "浏览 itch.io" : query
        )
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchURL: URL {
        if let customURL,
           let url = URL(string: customURL) {
            return url
        }

        var components = URLComponents(
            string: "https://itch.io/search"
        )!

        components.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]

        return components.url!
    }
}

// MARK: - WebView

private struct ItchWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(
        context: Context
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
