import SwiftUI
import WebKit

struct AuthorProfileView: View {
    let name: String
    let url: URL

    @AppStorage("itchPocket.appearance") private var appearanceMode = "light"

    private var localizedURL: URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "locale" }
        items.append(URLQueryItem(name: "locale", value: "zh_Hans"))
        components.queryItems = items
        return components.url ?? url
    }

    var body: some View {
        AuthorWebView(url: localizedURL, appearanceMode: appearanceMode)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemBackground))
    }
}

private struct AuthorWebView: UIViewRepresentable {
    let url: URL
    let appearanceMode: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        applyAppearance(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        applyAppearance(to: webView)
    }

    private func applyAppearance(to webView: WKWebView) {
        webView.overrideUserInterfaceStyle = appearanceMode == "dark" ? .dark : .light
        let scheme = appearanceMode == "dark" ? "dark" : "light"
        webView.evaluateJavaScript("document.documentElement.style.colorScheme = '\(scheme)';")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AuthorWebView
        init(parent: AuthorWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.applyAppearance(to: webView)
        }
    }
}
