import AppKit

@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()
    static let didLoad = Notification.Name("JNRemoteImageLoaded")

    nonisolated(unsafe) let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private var inFlight: Set<URL> = []
    private var failed: Set<URL> = []
    var session: URLSession = .shared

    nonisolated func imageOffMain(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.image(for: url) } }
        return nil
    }

    func image(for url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard url.scheme == "http" || url.scheme == "https", !inFlight.contains(url), !failed.contains(url) else { return nil }
        inFlight.insert(url)
        let session = self.session
        Task {
            self.finish(url, await Self.fetch(url, session: session))
        }
        return nil
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        return NSImage(data: data)
    }

    func finish(_ url: URL, _ image: NSImage?) {
        inFlight.remove(url)
        if let image, image.isValid {
            cache.setObject(image, forKey: url as NSURL)
            NotificationCenter.default.post(name: Self.didLoad, object: url)
        } else {
            failed.insert(url)
        }
    }
}
