import Foundation

// What this app reads from the web for a network, so the network itself fetches nothing (docs/NETWORK.md):
// each link's preview, sent after the post, and the member's Farcaster picture, sent after joining.
// Both are extras. A page or picture that can't be read leaves the post or the membership as it is.

enum NetworkPreviews {
    typealias Reader = @Sendable (URL) async -> LinkPreview?
    typealias Downloader = @Sendable (URL) async -> NetworkImage?

    /// Reads each link's page (the composer's read, if it made one), uploads its picture, and sends what
    /// it found for the post `hash`. Never throws: a preview that fails leaves the link without one.
    static func send(links: [String], hash: String, client: NetworkClient,
                     read: Reader = { await LinkPreview.load($0) },
                     download: Downloader = { await NetworkImage.download($0) }) async {
        var previews: [NetworkClient.LinkPreviewUpload] = []
        for link in links.prefix(NetworkMessages.maxEmbeds) {
            guard let url = URL(string: link), let read = await read(url), !read.isEmpty else { continue }
            var preview = NetworkClient.LinkPreviewUpload(url: link, title: read.title.flatMap(LinkPreview.networkText),
                                                          description: read.description.flatMap(LinkPreview.networkText))
            if let image = read.image, let picture = await download(image) {
                preview.image = try? await client.upload(picture.data, type: picture.type).id
            }
            if !preview.isEmpty { previews.append(preview) }
        }
        guard !previews.isEmpty else { return }
        try? await client.sendPreviews(hash, previews)
    }

    /// Downloads the Farcaster picture at `link`, uploads it, and makes it the member's Farcaster picture
    /// on this network. Returns the member as the network now has them, or nil if any step failed.
    @discardableResult
    static func sendFarcasterPicture(_ link: String, client: NetworkClient,
                                     download: Downloader = { await NetworkImage.download($0) }) async -> NetworkMember? {
        guard let url = URL(string: link), let picture = await download(url),
              let uploaded = try? await client.upload(picture.data, type: picture.type) else { return nil }
        return try? await client.setFarcasterPicture(uploaded.id)
    }
}

extension NetworkImage {
    /// A picture someone else's server holds, made ready for a network: only HTTPS to a named public
    /// host, through redirects too, with no cookies, a short timeout, and at most 10 MB read.
    static func download(_ url: URL) async -> NetworkImage? {
        guard FeedCast.imageURL(url.absoluteString) != nil else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/jpeg,image/png,image/gif,image/webp,image/*;q=0.8", forHTTPHeaderField: "accept")
        guard let (bytes, response) = try? await LinkPreview.session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= maxBytes else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return NetworkImage(data: data)
    }
}
