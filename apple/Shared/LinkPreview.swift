import Foundation

/// What a page says about itself, read from its Open Graph tags or its title. The composer shows it,
/// and a network post sends it to the network (`NetworkPreviews`), so the network reads no pages.
struct LinkPreview: Sendable, Equatable {
    var title: String?
    var description: String?
    /// The page's picture: HTTPS to a named public host, like any picture this device fetches.
    var image: URL?

    private static let maxBytes = 512 * 1024
    /// What a network takes for a preview's title or description: 300 characters on one line.
    static let maxText = 300
    @MainActor private static var cache: [URL: LinkPreview] = [:]
    /// No cookies and no cache, so a previewed site can't recognize this device from one preview to
    /// the next, and a redirect gets the same check as the link itself.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: CastImages.Redirects(), delegateQueue: nil)
    }()

    var isEmpty: Bool { title == nil && description == nil && image == nil }

    /// The first web address in the text, as `https`. Plain `http` stays text, since networks only carry secure links.
    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let found = Range(match.range, in: text) else { continue }
            let typed = text[found].lowercased()
            if url.scheme == "https" { return url }
            // A bare address like example.com/menu reads as http. Fatline gives it https.
            if url.scheme == "http", !typed.hasPrefix("http:"), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                parts.scheme = "https"
                if let secure = parts.url { return secure }
            }
        }
        return nil
    }

    /// Only HTTPS to a named public host, as for pictures, so typing a link can't make this device call
    /// something on its own network.
    @MainActor
    static func load(_ url: URL) async -> LinkPreview? {
        if let cached = cache[url] { return cached }
        guard FeedCast.imageURL(url.absoluteString) != nil, let preview = await fetch(url) else { return nil }
        cache[url] = preview
        return preview
    }

    /// Reads the page up to 512 KB and stops there, off the main thread, then reads its tags.
    private static func fetch(_ url: URL) async -> LinkPreview? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "accept")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
        } catch {
            guard !data.isEmpty else { return nil }
        }
        guard let html = text(data) else { return nil }
        // A relative picture is relative to where the page ended up, after any redirect.
        return parse(html, base: response.url ?? url)
    }

    /// UTF-8, allowing for a character cut in two at the end, or else Latin-1.
    private static func text(_ data: Data) -> String? {
        for cut in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(cut), encoding: .utf8) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// `base` is the page's address, for a picture given relative to it.
    static func parse(_ html: String, base: URL? = nil) -> LinkPreview {
        func content(_ names: [String]) -> String? {
            for name in names {
                let pattern = #"<meta[^>]+(?:property|name)\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: name) + #"["'][^>]*>"#
                guard let tag = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map({ String(html[$0]) }),
                      let attribute = tag.range(of: #"content\s*=\s*(["'])(.*?)\1"#, options: .regularExpression).map({ String(tag[$0]) })
                else { continue }
                let value = attribute.replacingOccurrences(of: #"^content\s*=\s*["']|["']$"#, with: "", options: .regularExpression)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
            return nil
        }
        func meta(_ names: [String]) -> String? {
            for name in names {
                if let value = content([name]).flatMap(clean) { return value }
            }
            return nil
        }
        let title = meta(["og:title", "twitter:title"]) ?? html
            .range(of: #"(?<=<title>)[^<]+"#, options: [.regularExpression, .caseInsensitive])
            .flatMap { clean(String(html[$0])) }
        let image = content(["og:image", "og:image:url", "twitter:image"])
            .map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            .flatMap { FeedCast.imageURL($0.absoluteString) }
        return LinkPreview(title: title, description: meta(["og:description", "twitter:description", "description"]), image: image)
    }

    /// Entities decoded, then what a network refuses taken out (`networkText`).
    private static func clean(_ text: String) -> String? {
        networkText(decodeEntities(text))
    }

    /// Text from someone's page as a network takes it: line breaks as spaces, nothing that hides or
    /// reverses text, spaces collapsed, and at most 300 characters. The same rules as `withoutHidden`
    /// and `textField` in network/src. Nil when nothing is left.
    static func networkText(_ text: String) -> String? {
        var scalars: [Unicode.Scalar] = []
        let all = Array(text.unicodeScalars)
        var index = 0
        while index < all.count {
            let scalar = all[index]
            // A region's flag is 🏴, three to six tag letters and digits, then the end tag. Other tags hide.
            if scalar.value == 0x1F3F4, let end = flagEnd(all, from: index + 1) {
                scalars.append(contentsOf: all[index...end])
                index = end + 1
                continue
            }
            index += 1
            if ["\n", "\r", "\t"].contains(scalar) {
                scalars.append(" ")
            } else if !hides(scalar) && !(0xE0000...0xE007F).contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        // Selectors with nothing of their own to vary, and joiners beside another joiner, show as nothing.
        var kept: [Unicode.Scalar] = []
        for scalar in scalars {
            let previous = kept.last
            if isSelector(scalar), previous.map({ isSelector($0) || isJoiner($0) }) ?? true { continue }
            if isJoiner(scalar), let previous, isJoiner(previous) { continue }
            kept.append(scalar)
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: kept)
        var cleaned = String(view)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Trimming can leave a selector at the start, which is one with nothing to vary.
        while let first = cleaned.unicodeScalars.first, isSelector(first) { cleaned.unicodeScalars.removeFirst() }
        if cleaned.count > maxText { cleaned = String(cleaned.prefix(maxText)) }
        // A network also caps a field at 1,200 UTF-16 units, which only piles of marks reach.
        while cleaned.utf16.count > maxText * 4 { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Where a flag's end tag is, if the tags after 🏴 at `start` spell one.
    private static func flagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start
        while index < scalars.count, (0xE0030...0xE0039).contains(scalars[index].value) || (0xE0061...0xE007A).contains(scalars[index].value) {
            index += 1
        }
        let letters = index - start
        guard (3...6).contains(letters), index < scalars.count, scalars[index].value == 0xE007F else { return nil }
        return index
    }

    /// What `HIDING` in network/src/protocol/text.ts lists: controls, bidi controls, and characters that
    /// show as nothing. The zero-width joiner and non-joiner stay, since emoji and Persian need them.
    private static func hides(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F...0x009F, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E,
             0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2060...0x206F, 0x2800, 0x3164, 0xFEFF, 0xFFA0:
            true
        default:
            false
        }
    }

    private static func isSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool { scalar.value == 0x200C || scalar.value == 0x200D }

    /// Named and numeric entities, as pages write them in tags.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let entity = try? NSRegularExpression(pattern: "&(?:#[xX]([0-9a-fA-F]{1,8})|#([0-9]{1,10})|(quot|apos|lt|gt|amp));")
        else { return text }
        let named = ["quot": "\"", "apos": "'", "lt": "<", "gt": ">", "amp": "&"]
        var decoded = ""
        var rest = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            decoded += text[rest..<whole.lowerBound]
            rest = whole.upperBound
            if let name = Range(match.range(at: 3), in: text) {
                decoded += named[String(text[name])] ?? ""
                continue
            }
            let hex = Range(match.range(at: 1), in: text)
            let digits = (hex ?? Range(match.range(at: 2), in: text)).map { String(text[$0]) }
            // One that isn't a character, like a lone surrogate, shows as the replacement character.
            let scalar = digits.flatMap { UInt32($0, radix: hex == nil ? 10 : 16) }.flatMap { $0 > 0 ? Unicode.Scalar($0) : nil }
            decoded += scalar.map { String($0) } ?? "\u{FFFD}"
        }
        return decoded + text[rest...]
    }
}
