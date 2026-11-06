
import SwiftUI
import BackgroundTasks
import UIKit

@main
struct itchPocketApp: App {
    @UIApplicationDelegateAdaptor(ItchPocketAppDelegate.self) private var appDelegate
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
