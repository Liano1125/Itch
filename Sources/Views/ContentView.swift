import SwiftUI

enum AppTab: Hashable {
    case discover
    case library
    case profile
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .discover
    @AppStorage("itchPocket.appearance") private var appearanceMode = "light"

    private let accent = Color(red: 0.94, green: 0.31, blue: 0.34)

    private var preferredScheme: ColorScheme {
        appearanceMode == "dark" ? .dark : .light
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem {
                    Label("发现", systemImage: "sparkles")
                }
                .tag(AppTab.discover)

            LibraryView()
                .tabItem {
                    Label("游戏库", systemImage: "square.grid.2x2")
                }
                .tag(AppTab.library)

            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
                .tag(AppTab.profile)
        }
        .tint(accent)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(preferredScheme)
        .animation(.easeInOut(duration: 0.22), value: appearanceMode)
    }
}
