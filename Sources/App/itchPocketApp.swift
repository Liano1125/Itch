import SwiftUI
import BackgroundTasks
import UIKit
import SwiftData

@main
struct itchPocketApp: App {
    @UIApplicationDelegateAdaptor(ItchPocketAppDelegate.self) private var appDelegate
    @StateObject private var authService = ItchAuthService()
    @State private var database: AppDatabase?
    @State private var databaseError: String?
    @State private var canRecoverFromLegacy = AppDatabase.hasLegacyStoreForRecovery

    init() {
        do {
            let database = try AppDatabase()
            AppDatabase.installShared(database)
            _database = State(initialValue: database)
            _databaseError = State(initialValue: nil)
        } catch {
            _database = State(initialValue: nil)
            _databaseError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let database {
                    ContentView()
                        .modelContainer(database.container)
                        .environmentObject(authService)
                        .task {
                            await authService.restoreSession()
                        }
                } else {
                    DatabaseRecoveryView(
                        errorMessage: databaseError ?? "数据库暂时无法打开。",
                        onRetry: retryDatabase,
                        onRecover: recoverFromLegacy,
                        canRecoverFromLegacy: canRecoverFromLegacy
                    )
                }
            }
        }
    }

    @MainActor
    private func retryDatabase() {
        do {
            let recoveredDatabase = try AppDatabase()
            AppDatabase.installShared(recoveredDatabase)
            database = recoveredDatabase
            databaseError = nil
        } catch {
            databaseError = error.localizedDescription
            canRecoverFromLegacy = AppDatabase.hasLegacyStoreForRecovery
        }
    }

    @MainActor
    private func recoverFromLegacy() {
        do {
            let recoveredDatabase = try AppDatabase(recoverCorruptV2: true)
            AppDatabase.installShared(recoveredDatabase)
            database = recoveredDatabase
            databaseError = nil
            canRecoverFromLegacy = false
        } catch {
            databaseError = error.localizedDescription
            canRecoverFromLegacy = AppDatabase.hasLegacyStoreForRecovery
        }
    }
}
