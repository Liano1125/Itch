import Foundation
import SwiftUI

enum LibraryStatus: String, CaseIterable, Codable, Identifiable {
    case wishlist = "想玩"
    case playing = "在玩"
    case completed = "已完成"
    case onHold = "暂不玩"
    case dropped = "已放弃"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .wishlist: return "bookmark"
        case .playing: return "gamecontroller"
        case .completed: return "checkmark.circle"
        case .onHold: return "pause.circle"
        case .dropped: return "xmark.circle"
        }
    }
}

struct LibraryRecord: Codable, Identifiable {
    var id: String
    var title: String
    var gameURL: String?
    var coverURL: String?
    var developer: String?
    var status: LibraryStatus
    var isFavorite: Bool
    var notes: String
    var addedAt: Date
    var updatedAt: Date
}

@MainActor
final class PersonalLibraryStore: ObservableObject {
    @Published private(set) var records: [LibraryRecord] = []
    private let storageKey = "itchPocket.personalLibrary.v1"

    init() { load() }

    func contains(_ id: String) -> Bool {
        records.contains { $0.id == id }
    }

    func add(_ game: PublicCollectionGame, status: LibraryStatus = .wishlist) {
        guard !contains(game.id) else { return }
        let now = Date()
        records.insert(
            LibraryRecord(
                id: game.id,
                title: game.title,
                gameURL: game.url?.absoluteString,
                coverURL: game.coverURL?.absoluteString,
                developer: game.developer,
                status: status,
                isFavorite: false,
                notes: "",
                addedAt: now,
                updatedAt: now
            ),
            at: 0
        )
        save()
    }

    func update(_ record: LibraryRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        var updated = record
        updated.updatedAt = Date()
        records[index] = updated
        save()
    }

    func remove(_ id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LibraryRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
