import Foundation
import SwiftUI
import UIKit

@MainActor
final class PersistentImageCache {
    static let shared = PersistentImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = caches.appendingPathComponent("itchPocket-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    func image(for url: URL?) async -> UIImage? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let key = url as NSURL
        if let cached = memory.object(forKey: key) { return cached }

        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
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

    private func fileURL(for url: URL) -> URL {
        let safeName = url.absoluteString
            .unicodeScalars
            .map { String($0.value, radix: 16) }
            .joined(separator: "-")
        return directory.appendingPathComponent(safeName).appendingPathExtension("img")
    }
}

struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

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
        .task(id: url) {
            image = await PersistentImageCache.shared.image(for: url)
        }
    }
}
