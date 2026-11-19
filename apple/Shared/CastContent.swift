import ImageIO
import SwiftUI

extension FeedCast {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Cast text with its web links made active. The server leaves a link out of `links` when the
    /// text already has it, so this is the only way to open those. Each link opens the address its
    /// own text spells out, and nothing else in the text changes.
    static func linkedText(_ text: String) -> AttributedString {
        var linked = AttributedString(text)
        let matches = linkDetector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        // Each link is a nested piece of text, so a cast of nothing but links can't be allowed to make thousands.
        for match in matches.prefix(20) {
            guard var url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", let host = url.host()?.lowercased(),
                  // A host in another alphabet can look just like a familiar one, so it stays plain text.
                  host.allSatisfy(\.isASCII), !host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }),
                  let range = Range(match.range, in: linked) else { continue }
            // The detector assumes http for a bare address. Only an address written with http keeps it.
            if scheme == "http", let written = Range(match.range, in: text), !text[written].lowercased().hasPrefix("http:"),
               let secure = URL(string: "https" + url.absoluteString.dropFirst(4)) {
                url = secure
            }
            linked[range].link = url
            linked[range][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        }
        return linked
    }
}

/// Downloads and shrinks avatars and cast pictures. Shrunk images stay in memory so a row scrolled back
/// into view draws at its final size, and the downloads themselves are cached on disk between launches.
/// A cast's author picks these addresses, so a download and the image inside it both have a size limit.
@MainActor
enum CastImages {
    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// A redirect gets the same check as the address in the cast, or a host could use one to get around it.
    final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            request.url.flatMap { FeedCast.imageURL($0.absoluteString) } == nil ? nil : request
        }
    }

    /// How large a cast's picture is kept for the feed, and for the iPhone's picture viewer, which
    /// zooms in. The viewer shows the feed's copy until its own loads.
    static let feedPicturePixels = 1400
    static let viewerPicturePixels = 3072

    nonisolated private static let maxDownloadBytes = 25_000_000
    nonisolated private static let maxSourcePixels = 100_000_000
    /// The formats people post. The system can read dozens more, like camera RAW, and each one is more
    /// decoding code that a stranger's file could reach.
    nonisolated private static let formats: Set<String> = [
        "public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.avif"
    ]
    private static let memory: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = Platform.imageMemoryLimit
        return cache
    }()
    private static var loading: [String: Task<Loaded, Never>] = [:]
    private static let movedKey = "pictureCacheMoved"
    private static let session: URLSession = {
        // Builds up to 15 kept pictures in the default folder, which `URLCache.shared` also uses.
        // Clear them out of there once.
        if !UserDefaults.standard.bool(forKey: movedKey) {
            URLCache.shared.removeAllCachedResponses()
            UserDefaults.standard.set(true, forKey: movedKey)
        }
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: Platform.imageDiskLimit, directory: Platform.pictureCacheFolder)
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()
    /// Bumped after each feed read, so a picture that failed tries again then. See `retryRound`.
    @Observable final class Retries { var round = 0 }
    private static let retries = Retries()
    /// Debug's fresh downloads, which keep nothing, so a check never changes what the feed has cached.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: Redirects(), delegateQueue: nil)
    }()

    // This launch's pictures, by scope (a network's host, or Farcaster), for Debug.
    private(set) static var loadedCount: [String: Int] = [:]
    private(set) static var failedCount: [String: Int] = [:]
    private static var startedAt: [String: (scope: String, at: Date)] = [:]

    /// A download, and the image in it or why there isn't one.
    private struct Loaded: Sendable {
        let image: CGImage?
        /// In a few words, such as "HTTP 403" or "didn't decode (image/avif)".
        let problem: String?
    }

    /// What came back for a picture's address.
    struct Fetched: Sendable {
        var data: Data?
        var status: Int?
        var type: String?
        /// Why there's no data, in a few words.
        var problem: String?
    }

    /// One picture as Debug tried it: fetched fresh or from the cache alone, then decoded as the feed would.
    struct Probe: Sendable {
        let fetched: Fetched
        let decoded: Bool
    }

    /// A network's picture links change each hour, so its pictures are kept by host, ID, and size instead.
    private static func key(_ url: URL, _ maxPixels: Int) -> String {
        if url.path().hasPrefix("/media/"), let host = url.host() { return "\(maxPixels) \(host):\(url.port ?? 0)\(url.path())" }
        return "\(maxPixels) \(url.absoluteString)"
    }

    /// Where a picture belongs, for the Launch Log and Debug's counts: the network serving it, or Farcaster.
    nonisolated static func scope(of url: URL) -> String {
        guard url.path().hasPrefix("/media/"), let host = url.host() else { return LaunchLog.farcaster }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    /// Downloads in `scope` still going after `seconds`.
    static func waiting(_ scope: String, longerThan seconds: TimeInterval) -> Int {
        startedAt.values.filter { $0.scope == scope && Date.now.timeIntervalSince($0.at) > seconds }.count
    }

    /// What the downloads cached on disk take up.
    static var cacheBytes: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }

    static func cached(_ url: URL, maxPixels: Int) -> CGImage? {
        memory.object(forKey: key(url, maxPixels) as NSString)?.image
    }

    /// Goes up after each feed read. A picture that failed puts this in its `.task(id:)`, so it tries
    /// again on the next read instead of staying "Image unavailable" until its row is rebuilt.
    static var retryRound: Int { retries.round }

    /// A feed was read: pictures that failed may try again.
    static func feedRead() { retries.round += 1 }

    static func load(_ url: URL, maxPixels: Int) async -> CGImage? {
        if let found = cached(url, maxPixels: maxPixels) { return found }
        let key = key(url, maxPixels)
        if let running = loading[key] { return await running.value.image }
        let session = session
        let scope = scope(of: url)
        let task = Task.detached(priority: .utility) { () -> Loaded in
            let fetched = await fetch(url, session: session)
            let loaded: Loaded
            if let data = fetched.data {
                let image = decode(data, maxPixels: maxPixels)
                loaded = Loaded(image: image, problem: image == nil ? undecodable(data, fetched.type) : nil)
            } else {
                loaded = Loaded(image: nil, problem: fetched.problem ?? "failed")
            }
            // A network marks its pictures immutable for a day, so a broken download kept on disk would
            // fail the same way at every try, and after a relaunch too. Drop it so a retry downloads again.
            if loaded.image == nil { session.configuration.urlCache?.removeCachedResponse(for: request(for: url)) }
            return loaded
        }
        loading[key] = task
        startedAt[key] = (scope, .now)
        let loaded = await task.value
        loading[key] = nil
        startedAt[key] = nil
        if let image = loaded.image {
            memory.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
            loadedCount[scope, default: 0] += 1
        } else {
            failedCount[scope, default: 0] += 1
            LaunchLog.record(.failed, "Picture failed", loaded.problem ?? "failed", scope: scope)
        }
        return loaded.image
    }

    /// For Debug: one picture fetched without the cache (`fresh`), or from the cache alone, then decoded.
    /// Neither changes what's cached.
    static func probe(_ url: URL, fresh: Bool) async -> Probe {
        let chosen = fresh ? probeSession : session
        let policy: URLRequest.CachePolicy = fresh ? .reloadIgnoringLocalCacheData : .returnCacheDataDontLoad
        let pixels = feedPicturePixels
        return await Task.detached(priority: .utility) { () -> Probe in
            let fetched = await fetch(url, session: chosen, cachePolicy: policy)
            return Probe(fetched: fetched, decoded: fetched.data.map { decode($0, maxPixels: pixels) != nil } ?? false)
        }.value
    }

    /// Why data that arrived isn't a picture, in a few words. Empty files get their own words, since a
    /// broken cache can hand back nothing with a good status.
    nonisolated static func undecodable(_ data: Data, _ type: String?) -> String {
        "\(data.isEmpty ? "empty" : "didn't decode") (\(type ?? "no type"))"
    }

    /// Reads as it goes, so a huge file is dropped at the limit instead of filling memory first.
    nonisolated static func fetch(_ url: URL, session: URLSession, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async -> Fetched {
        let request = request(for: url, cachePolicy: cachePolicy)
        let answer: (URLSession.AsyncBytes, URLResponse)
        do {
            answer = try await session.bytes(for: request)
        } catch {
            return Fetched(problem: describe(error))
        }
        let (bytes, response) = answer
        defer { bytes.task.cancel() }
        let http = response as? HTTPURLResponse
        var result = Fetched(status: http?.statusCode, type: http?.value(forHTTPHeaderField: "content-type"))
        guard let status = http?.statusCode, status == 200 else {
            result.problem = "HTTP \(http?.statusCode ?? 0)"
            return result
        }
        guard response.expectedContentLength <= maxDownloadBytes else {
            result.problem = "too large"
            return result
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxDownloadBytes {
                    result.problem = "too large"
                    return result
                }
            }
        } catch {
            result.problem = describe(error)
            return result
        }
        result.data = data
        return result
    }

    nonisolated private static func request(for url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        // A network serves smaller AVIF or WebP files to devices that ask for them.
        if url.path().hasPrefix("/media/") { request.setValue("image/avif,image/webp,image/*;q=0.8", forHTTPHeaderField: "accept") }
        return request
    }

    nonisolated private static func describe(_ error: Error) -> String {
        guard let error = error as? URLError else { return "failed" }
        switch error.code {
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "offline"
        case .networkConnectionLost: return "connection lost"
        case .cancelled: return "cancelled"
        case .resourceUnavailable, .cannotLoadFromNetwork: return "not cached"
        default: return "network error \(error.code.rawValue)"
        }
    }

    /// Whether a picture's stated size is small enough to decode: both sides set, and the pixel count
    /// within the limit. Sizes can claim nearly 2³² a side, so a product that wraps around fails too.
    nonisolated static func acceptsSize(width: Int, height: Int) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && width > 0 && height > 0 && pixels <= maxSourcePixels
    }

    nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), formats.contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              acceptsSize(width: width, height: height) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }
}
