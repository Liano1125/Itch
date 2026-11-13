import SwiftUI


enum AppTab: String, Hashable {
    case discover
    case library
    case calendar
    case profile
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var personalLibrary = PersonalLibraryStore.shared
    @StateObject private var gameCalendar = GameCalendarStore.shared
    @StateObject private var updateMonitor = GameUpdateMonitorStore.shared
    @StateObject private var sparkSync = SparkSyncStore.shared
    @AppStorage("itchPocket.launchTab") private var launchTab = "discover"
    @State private var selectedTab: AppTab
    @AppStorage("itchPocket.appearance") private var appearanceMode = "light"

    init() {
        let savedTab = UserDefaults.standard.string(forKey: "itchPocket.launchTab") ?? "discover"
        _selectedTab = State(initialValue: AppTab(rawValue: savedTab) ?? .discover)
    }

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

            GameCalendarView()
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
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .preferredColorScheme(preferredScheme)
        .animation(.easeInOut(duration: 0.22), value: appearanceMode)
        .onChange(of: launchTab) { _, value in
            selectedTab = AppTab(rawValue: value) ?? .discover
        }
        .environmentObject(personalLibrary)
        .environmentObject(gameCalendar)
        .environmentObject(updateMonitor)
        .task {
            try? await AppCacheManager.pruneExpiredCaches()
            await sparkSync.rescan(library: personalLibrary)
            DevlogAutoSync.scheduleNext()
            // Respect the six-hour throttle on cold launch as well as foregrounding.
            await DevlogAutoSync.refreshIfNeeded(
                monitor: updateMonitor,
                library: personalLibrary,
                calendar: gameCalendar
            )
            Task(priority: .utility) {
                await DevlogAutoSync.prefetchCalendarTranslations(events: gameCalendar.events)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await sparkSync.rescan(library: personalLibrary)
                await DevlogAutoSync.refreshIfNeeded(
                    monitor: updateMonitor,
                    library: personalLibrary,
                    calendar: gameCalendar
                )
                await DevlogAutoSync.prefetchCalendarTranslations(events: gameCalendar.events)
                await GameDetailPrefetchService.shared.prefetch(
                    records: personalLibrary.records,
                    library: personalLibrary
                )
            }
        }
    }
}
