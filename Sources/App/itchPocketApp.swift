
import SwiftUI
import BackgroundTasks
import UIKit
import SwiftData

@main
struct itchPocketApp: App {
    @UIApplicationDelegateAdaptor(ItchPocketAppDelegate.self) private var appDelegate
    @StateObject private var authService = ItchAuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(AppDatabase.shared.container)
                .environmentObject(authService)
                .task {
                    await authService.restoreSession()
                }
         }
    }
}
