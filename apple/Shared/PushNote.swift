import CryptoKit
import Foundation

/// A network's notification as the iPhone's notification extension opens it: the sealed note from
/// the relay's `s`, opened with the key this device made for that network, and the words the app
/// writes from it. The network never words a notification itself, so it can't pose as another
/// network or as the system. docs/NETWORK.md, Notifications; design/push-notifications-plan.md.
struct PushNote: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case post, reply, mention, approved, request, report, test }

    let kind: Kind
    /// Who posted, replied, mentioned, asked, or reported. For `approved` and `test`, the person it's for.
    let fid: UInt64
    let username: String
    let text: String
    let pictures: Int
    /// The new post or reply, or the reported post, as `0x` and 40 hex digits. Nil for `approved`
    /// and `request`, or when the network sent something else.
    let post: String?
    /// The top-level post: the post itself, or the one a reply answers.
    let thread: String?
    /// New posts only: how many this device has heard of this hour, this one included.
    let count: Int
    /// New posts only: up to three of their authors, most recent first.
    let usernames: [String]

    /// What iOS shows: the network's name as this device saved it at join, and the words.
    struct Words: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// The relay takes at most this many characters of `sealed`.
    static let maxSealedCharacters = 3_072
    /// The longest text the app shows, as the network caps it.
    static let maxTextCharacters = 280

    /// Opens a sealed note, or nil when it isn't one: a wrong key, a changed byte, a version or kind
    /// this app doesn't know. iOS then shows the relay's fallback words.
    static func open(_ sealed: String, key: SymmetricKey) -> PushNote? {
        guard let plaintext = try? unseal(sealed, key: key) else { return nil }
        return try? PushNote(json: plaintext)
    }

    /// The note's bytes: base64url, without padding, of the 12-byte nonce, the ciphertext, and the
    /// 16-byte tag, AES-256-GCM with no associated data.
    static func unseal(_ sealed: String, key: SymmetricKey) throws -> Data {
        guard key.bitCount == 256, let combined = Data(base64URL: sealed, maxCharacters: maxSealedCharacters),
              combined.count >= 12 + 16 else { throw CryptoKitError.incorrectParameterSize }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    }

    init(json: Data) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: json)
        guard wire.v == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown version \(wire.v)")) }
        kind = wire.kind
        fid = wire.fid
        // An account without a username comes as "!" and its FID, which the fallback writes the same way.
        username = Self.usable(wire.username) ?? "!\(wire.fid)"
        text = Self.cleaned(wire.text ?? "")
        pictures = max(0, wire.pictures ?? 0)
        post = wire.post.flatMap(Self.hash)
        thread = wire.thread.flatMap(Self.hash)
        count = max(1, wire.count ?? 1)
        usernames = (wire.usernames ?? []).prefix(3).compactMap(Self.usable)
    }

    func words(network: String) -> Words {
        Words(title: network, body: body)
    }

    private var who: String { username.hasPrefix("!") ? username : "@\(username)" }

    private var body: String {
        switch kind {
        case .post:
            if count > 1 {
                let posts = "\(count) new posts"
                return usernames.isEmpty ? posts : "\(posts) from \(Self.list(usernames))"
            }
            return text.isEmpty ? "\(who) posted \(picturesPhrase)" : "\(who): \(text)"
        case .reply:
            if !text.isEmpty { return "\(who) replied: \(text)" }
            return pictures > 0 ? "\(who) replied with \(picturesPhrase)" : "\(who) replied"
        case .mention:
            return text.isEmpty ? "\(who) mentioned you" : "\(who) mentioned you: \(text)"
        case .approved:
            return "You’re in."
        case .request:
            return "\(who) asked to join"
        case .report:
            return "\(who) reported a post"
        case .test:
            return "Test notification. This iPhone hears from this network."
        }
    }

    private var picturesPhrase: String { pictures > 1 ? "\(pictures) pictures" : "a picture" }

    /// "mika", "mika and sana", "mika, sana, and dave".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: names.first ?? ""
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    /// A Farcaster username the app will show: only lowercase letters, digits, hyphens, and dots (for
    /// `.eth` names), so a network can't write words such as "Apple ID:" where a name goes.
    private static func usable(_ username: String?) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard let username, (1...64).contains(username.utf8.count), username.first != ".", username.first != "-",
              username.allSatisfy(allowed.contains) else { return nil }
        return username
    }

    /// The post's text without characters that hide or reorder what's around them, and at most 280
    /// characters, ending in "…" when cut.
    private static func cleaned(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !hides(scalar) { scalars.append(scalar) }
        let kept = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.count > maxTextCharacters ? String(kept.prefix(maxTextCharacters - 1)) + "…" : kept
    }

    /// Controls other than a line break, and the marks that reverse text direction. Emoji joiners stay.
    private static func hides(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" { return false }
        if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            || [0x061C, 0x200E, 0x200F].contains(scalar.value) { return true }
        return scalar.properties.generalCategory == .control
    }

    private static func hash(_ text: String) -> String? {
        let digits = text.dropFirst(2)
        guard text.hasPrefix("0x"), digits.count == 40, digits.allSatisfy(\.isHexDigit) else { return nil }
        return text.lowercased()
    }

    private struct Wire: Decodable {
        let v: Int
        let kind: Kind
        let fid: UInt64
        let username: String?
        let text: String?
        let pictures: Int?
        let post: String?
        let thread: String?
        let count: Int?
        let usernames: [String]?
    }
}

extension Data {
    /// Reads base64url without padding (`A–Z a–z 0–9 - _`), as the network writes sealed notes.
    init?(base64URL text: String, maxCharacters: Int) {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...maxCharacters).contains(text.count), text.count % 4 != 1, text.allSatisfy(alphabet.contains) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        self.init(base64Encoded: standard)
    }
}
