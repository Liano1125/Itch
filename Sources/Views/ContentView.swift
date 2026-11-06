import SwiftUI

enum AppTab: Hashable {
    case discover
    case library
    case downloads
    case profile
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .discover

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem {
                    Label("发现", systemImage: "sparkle.magnifyingglass")
                }
                .tag(AppTab.discover)

            LibraryView()
                .tabItem {
                    Label("游戏库", systemImage: "books.vertical")
                }
                .tag(AppTab.library)

            DownloadsView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tag(AppTab.downloads)

            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(AppTab.profile)
        }
        .tint(.primary)
    }
}
