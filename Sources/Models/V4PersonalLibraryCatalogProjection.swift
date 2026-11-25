import Foundation

extension V4PersonalLibraryStore {
    /// Reloads the signed-in account's library with shared catalog metadata.
    /// Personal fields always come from account-filtered V4 rows; shared
    /// title/developer/detail fields come from the global catalog.
    func reloadLibraryGames() throws {
        guard let request = dependencies.session.captureRequestContext() else {
            publishLibraryGames([])
            throw StoreError.noCurrentAccount
        }
        let repository = AccountScopedLibraryCatalogRepository(
            context: dependencies.modelContext,
            accountID: request.accountID
        )
        let loaded = try repository.loadLibraryGames()
        try validateCurrent(request)
        publishLibraryGames(loaded)
    }
}
