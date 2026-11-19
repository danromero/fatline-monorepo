import Foundation

/// A link to a post in a network: the page's button, `fatline://open?network=<host>&post=<hash>`, or the
/// post's own address, `https://<host>/p/<hash>`, which opens the app straight away where the network's
/// domain is associated with it (universal links). Anything else isn't one.
struct PostLink: Equatable, Hashable, Sendable {
    let host: String
    let hash: String

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let typedHost: String?
        let typedHash: String?
        switch parts.scheme?.lowercased() {
        case "fatline":
            guard parts.host?.lowercased() == "open", parts.path.isEmpty || parts.path == "/" else { return nil }
            typedHost = parts.queryItems?.first { $0.name == "network" }?.value
            typedHash = parts.queryItems?.first { $0.name == "post" }?.value
        case "https", "http":
            // `/p/<hash>`, nothing more, on the network's own address.
            let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 3, segments[0].isEmpty, segments[1] == "p", let name = parts.host else { return nil }
            typedHost = "\(parts.scheme!)://\(name)" + (parts.port.map { ":\($0)" } ?? "")
            typedHash = String(segments[2])
        default:
            return nil
        }
        // The same checks as an address typed into Add Network, so a link can't name anything a person couldn't.
        guard let typedHost, let host = NetworkMessages.host(from: typedHost),
              let hash = typedHash?.lowercased(), Self.isHash(hash) else { return nil }
        self.host = host
        self.hash = hash
    }

    /// `0x` and 40 hex digits, as every post's hash is.
    static func isHash(_ text: String) -> Bool {
        text.count == 42 && text.hasPrefix("0x") && text.dropFirst(2).allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
