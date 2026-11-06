import SwiftUI

enum AppTab: Hashable {
    case discover
    case library
    case calendar
    case profile
}

struct ContentView: View {
    @StateObject private var personalLibrary = PersonalLibraryStore()
    @StateObject private var gameCalendar = GameCalendarStore()
    @StateObject private var updateMonitor = GameUpdateMonitorStore()
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

            NavigationStack {
                VStack(spacing: 0) {
                    NavigationLink {
                        GameUpdateMonitorView()
                    } label: {
                        HStack {
                            Label("游戏更新提醒", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                    GameCalendarView()
                }
            }
                .tabItem {
                    Label("日历", systemImage: "calendar")
                }
                .tag(AppTab.calendar)

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
        .environmentObject(personalLibrary)
        .environmentObject(gameCalendar)
        .environmentObject(updateMonitor)
    }
}
