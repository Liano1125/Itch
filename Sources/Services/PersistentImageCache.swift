import Foundation
import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class PersistentImageCache {
    static let shared = PersistentImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        directory = (try? AppDataStore.cachesDirectory(named: "itchPocket-images"))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("itchPocket-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    func image(for url: URL?) async -> UIImage? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let requestKey = url.absoluteString
        if let existing = inFlight[requestKey] {
            return await existing.value
        }

        let task = Task { await self.loadImage(for: url) }
        inFlight[requestKey] = task
        let result = await task.value
        inFlight.removeValue(forKey: requestKey)
        return result
    }

    private func loadImage(for url: URL) async -> UIImage? {
        let key = url as NSURL
        if let cached = memory.object(forKey: key) { return cached }

        let file = fileURL(for: url)
        let diskData = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: file, options: .mappedIfSafe)
        }.value
        if let data = diskData, let image = UIImage(data: data) {
            memory.setObject(image, forKey: key)
            return image
        }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            try? data.write(to: file, options: .atomic)
            memory.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = await self.image(for: url)
                }
            }
        }
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(fileName).appendingPathExtension("img")
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var fallbackURL: URL? = nil
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    private var requestKey: String {
        "\(url?.absoluteString ?? "")|\(fallbackURL?.absoluteString ?? "")"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: requestKey) {
            image = nil
            let primaryImage = await PersistentImageCache.shared.image(for: url)
            if let primaryImage {
                image = primaryImage
            } else {
                image = await PersistentImageCache.shared.image(for: fallbackURL)
            }
        }
    }
}
