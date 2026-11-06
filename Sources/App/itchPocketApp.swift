
import SwiftUI

@main
struct itchPocketApp: App {
    @StateObject private var authService = ItchAuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .task {
                    await authService.restoreSession()
                }
         }
    }
}
