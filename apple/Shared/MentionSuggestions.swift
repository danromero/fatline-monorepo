import Foundation

/// The @name being typed in a network's composer, and the members it could be. Typing @ suggests the
/// network's members, people you've talked with first, and a tap puts in @username, which the post
/// sends as a mention. Networks only: Farcaster would need a people search the app doesn't have.
enum MentionSuggestions {
    /// How many members show at once, so the list leaves room for the text above the keyboard.
    static let limit = 3

    /// The @name just before the caret: its range, from the @, and the letters typed after it. Nil
    /// when the caret isn't in one. The @ has to start a word, so an email address doesn't count.
    static func query(in text: String, caret: String.Index) -> (range: Range<String.Index>, name: String)? {
        guard caret <= text.endIndex else { return nil }
        var start = caret
        while start > text.startIndex {
            let before = text.index(before: start)
            let character = text[before]
            if character == "@" {
                let startsWord = before == text.startIndex || opensWord(text[text.index(before: before)])
                return startsWord ? (before..<caret, String(text[start..<caret])) : nil
            }
            guard isNameCharacter(character) else { return nil }
            start = before
        }
        return nil
    }

    /// The members whose username or name starts with what's typed, leaving out you and people you
    /// muted. Those you've talked with come first, the most recent first, then the rest by username.
    static func members(matching name: String, in members: [NetworkMember], you: UInt64?,
                        talkedWith: [UInt64: Int64]) -> [NetworkMember] {
        let typed = name.lowercased()
        let matches = members.filter { member in
            guard member.fid != you, !member.muted, !member.username.isEmpty else { return false }
            if typed.isEmpty { return true }
            if member.username.lowercased().hasPrefix(typed) { return true }
            return member.displayName.lowercased().split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(typed) }
        }
        return matches.sorted { first, second in
            let one = talkedWith[first.fid], two = talkedWith[second.fid]
            if one != two { return (one ?? .min) > (two ?? .min) }
            return first.username.lowercased() < second.username.lowercased()
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Who you've talked with in these posts, with the time of the latest: whoever replied to you or
    /// mentioned you, and whoever you replied to or mentioned.
    static func talkedWith(in posts: [NetworkPost], you: UInt64) -> [UInt64: Int64] {
        var latest: [UInt64: Int64] = [:]
        func saw(_ fid: UInt64, _ time: Int64) {
            guard fid != you else { return }
            latest[fid] = max(latest[fid] ?? .min, time)
        }
        for post in posts where !post.deleted {
            if post.fid == you {
                if let parent = post.parentFid { saw(parent, post.time) }
                for mention in post.mentions { saw(mention.fid, post.time) }
            } else if post.parentFid == you || post.mentions.contains(where: { $0.fid == you }) {
                saw(post.fid, post.time)
            }
        }
        return latest
    }

    /// The text with the @name at `range` replaced by the whole username and a space, and where the
    /// caret goes after it.
    static func complete(_ text: String, range: Range<String.Index>, with username: String) -> (text: String, caret: String.Index) {
        var completed = text
        let inserted = "@\(username) "
        completed.replaceSubrange(range, with: inserted)
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + inserted.count
        return (completed, completed.index(completed.startIndex, offsetBy: offset))
    }

    /// Farcaster usernames: letters, digits, hyphens, and the dots in .eth names. Underscores too, so a
    /// network's own usernames work.
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
    }

    private static func opensWord(_ character: Character) -> Bool {
        character.isWhitespace || "([{\"'“‘".contains(character)
    }
}
