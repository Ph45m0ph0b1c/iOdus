import AppKit
import SwiftUI

/// Loads remote art with a memory cache and a disk cache in
/// ~/Library/Caches/iOdus. Two requests for one URL share one download.
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    let session: URLSession
    private let memory = NSCache<NSURL, NSImage>()
    private var running: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iOdus/images", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 1 << 30, directory: caches)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.totalCostLimit = 256 << 20
    }

    /// The Store image service can resize. Ask for the width that the UI needs.
    /// Asks the Store image service for a smaller image. Other hosts (for
    /// example the Xbox profile pictures) keep their URL unchanged.
    static func sized(_ url: URL, width: Int) -> URL {
        guard url.host?.hasSuffix("s-microsoft.com") == true else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "w", value: String(width))]
        return components?.url ?? url
    }

    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let task = running[url] { return await task.value }
        let session = self.session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return NSImage(data: data)
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

/// A remote image that fills its frame, with a fallback view while it loads.
struct RemoteImage<Fallback: View>: View {
    let url: URL?
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: NSImage?

    var body: some View {
        // The image fills the space that the parent offers. Color.clear sets the
        // layout size, so that a wide image cannot make the parent wider.
        Color.clear
            .overlay {
                ZStack {
                    fallback()
                    if let shown = image ?? url.flatMap({ ImageStore.shared.cached($0) }) {
                        Image(nsImage: shown)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
            }
            .clipped()
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await ImageStore.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
