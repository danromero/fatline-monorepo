import SwiftUI

/// What Activity has read, for one visit: the replies and mentions, and on iPhone likes, where New
/// ends, and for an admin how many are waiting to join.
@MainActor
@Observable
final class NetworkActivityState {
    private(set) var items: [NetworkActivity.Item] = []
    private(set) var loaded = false
    private(set) var failure: String?
    /// The newest reply or mention Activity had shown when this visit began. Ones after it are New.
    private(set) var seenBefore: Int64?
    /// The same for likes, by when each post was last liked, which has a seen time of its own.
    private(set) var likesSeenBefore: Int64?
    private(set) var waiting = 0

    /// A visit begins. Call it before `load`, which marks everything seen.
    func begin(_ model: NetworkModel) {
        seenBefore = model.activitySeen
        likesSeenBefore = model.likesSeen
    }

    /// Reading Activity marks it seen, which clears its dot.
    func load(_ model: NetworkModel, admin: Bool) async {
        do {
            items = try await model.activity()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        if admin { waiting = (try? await model.waitingRequests()) ?? waiting }
        loaded = true
    }

    func isNew(_ item: NetworkActivity.Item) -> Bool {
        (item.isLike ? likesSeenBefore : seenBefore).map { item.when > $0 } ?? false
    }
}

/// A like's row in Activity: who liked your post, and the post on one line.
enum NetworkLikeRow {
    /// A piece of the header. Names are bold, the words around them aren't.
    struct Piece: Equatable {
        let text: String
        var isName = false
    }

    /// "helen liked your post", "helen and theo…", "helen, theo, and sana…", and past three names,
    /// "helen, theo, and 3 others…". `names` are the newest likers, newest first.
    static func header(names: [String], count: Int, reply: Bool) -> [Piece] {
        let count = max(count, names.count)
        // Everyone by name up to three, or else two names and the rest as a number.
        let shown = count <= names.count ? Array(names.prefix(count)) : Array(names.prefix(2))
        let others = count - shown.count
        var parts = shown.map { Piece(text: $0, isName: true) }
        if others > 0 { parts.append(Piece(text: others == 1 ? "1 other" : "\(others) others")) }
        var pieces: [Piece] = []
        for (index, part) in parts.enumerated() {
            if index > 0 {
                let last = index == parts.count - 1
                pieces.append(Piece(text: parts.count == 2 ? " and " : last ? ", and " : ", "))
            }
            pieces.append(part)
        }
        pieces.append(Piece(text: reply ? " liked your reply" : " liked your post"))
        return pieces
    }

    /// The liked post on one line: its text, or for one without, its link, or that it's a picture.
    static func summary(of post: NetworkPost) -> String {
        let text = post.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return text }
        if let link = post.embeds.first(where: { $0.type == "link" })?.url.flatMap(URL.init(string:)) {
            return FeedCast.label(for: link)
        }
        let pictures = post.embeds.filter { $0.type == "image" }.count
        if pictures > 0 { return pictures == 1 ? "Picture" : "\(pictures) pictures" }
        if post.embeds.contains(where: { $0.type == "post" }) { return "Quoted post" }
        return post.parent == nil ? "Post" : "Reply"
    }

    /// The liked post's line on iPhone, where its first picture shows at the row's trailing edge: none
    /// for a post that's only pictures, since the picture says it.
    static func caption(of post: NetworkPost, pictureShown: Bool) -> String? {
        let onlyPictures = post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !post.embeds.contains { $0.type == "link" } && post.embeds.contains { $0.type == "image" }
        return pictureShown && onlyPictures ? nil : summary(of: post)
    }
}

#if os(iOS)
/// An Activity row on iPhone, as on X: what happened as a glyph in the avatar's column, the people's
/// pictures over one sentence that ends in when, a line of the post, and your post's first picture at
/// the trailing edge.
struct NetworkActivityRow: View {
    struct Person: Hashable {
        let url: URL?
        let handle: String
    }

    let glyph: String
    let people: [Person]
    /// Names bold, the words around them regular.
    let sentence: Text
    let date: Date
    /// For a like, your post, in gray on up to two lines. For a reply or mention, their words.
    let line: String?
    var lineIsTheirs = false
    let picture: FeedCast.Picture?

    var body: some View {
        HStack(alignment: .center, spacing: FatlineStyle.gutter) {
            HStack(alignment: .top, spacing: FatlineStyle.avatarGap) {
                Image(systemName: glyph)
                    .font(FatlineStyle.rowGlyph)
                    .foregroundStyle(FatlineStyle.action)
                    .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.activityAvatarSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FatlineStyle.itemGap) {
                    faces
                    VStack(alignment: .leading, spacing: FatlineStyle.castGap) {
                        TimelineView(.everyMinute) { context in
                            // No-break spaces keep the time with the sentence's last word.
                            let age = Text(verbatim: "\u{00A0}·\u{00A0}" + FeedCast.shortAge(of: date, at: context.date))
                                .font(FatlineStyle.body)
                                .foregroundStyle(FatlineStyle.secondary)
                            Text("\(sentence)\(age)")
                                .lineSpacing(FatlineStyle.bodyLineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let line {
                            Text(verbatim: line)
                                .font(FatlineStyle.body)
                                .lineSpacing(FatlineStyle.bodyLineSpacing)
                                .foregroundStyle(lineIsTheirs ? FatlineStyle.ink : FatlineStyle.secondary)
                                .lineLimit(lineIsTheirs ? nil : 2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let picture {
                CastPicture(url: picture.url, ratio: picture.ratio, layout: .activity)
            }
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FatlineStyle.paper)
    }

    /// Their pictures in a row, each over the next, with a paper ring between them.
    private var faces: some View {
        HStack(spacing: -FatlineStyle.activityAvatarOverlap) {
            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                CastAvatar(url: person.url, handle: person.handle, size: FatlineStyle.activityAvatarSize)
                    .background { Circle().fill(FatlineStyle.paper).padding(-FatlineStyle.unreadRing) }
                    .zIndex(Double(people.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}
#endif

/// Activity's rows, in both apps: what arrived since the last look under New, and the rest under
/// Earlier. Each row opens the replies it's part of, and an admin sees requests to join first. iPhone's
/// rows are X's (`NetworkActivityRow`); on a Mac a reply shows the post it answers in a quiet card. It
/// goes inside the screen's own scrolling stack.
struct NetworkActivityList: View {
    let activity: NetworkActivityState
    let model: NetworkModel
    let membership: NetworkMembership
    let open: (NetworkPost) -> Void

    @Environment(\.openURL) private var openURL
    @State private var opening = false
    @State private var problem: String?

    var body: some View {
        let new = activity.items.filter(activity.isNew)
        let earlier = activity.items.filter { !activity.isNew($0) }
        let waiting = membership.isAdmin ? activity.waiting : 0
        let hasNew = waiting > 0 || !new.isEmpty
        Group {
            if let failure = activity.failure {
                FeedMessage(text: failure, color: FatlineStyle.danger)
            } else if activity.loaded && activity.items.isEmpty && waiting == 0 {
                FeedMessage(text: "No activity yet")
            }
            if hasNew {
                SectionLabel(text: "New")
                if waiting > 0 {
                    requests(waiting)
                    if !new.isEmpty || !earlier.isEmpty { CastDivider() }
                }
                rows(new, last: earlier.isEmpty)
            }
            if !earlier.isEmpty {
                if hasNew { SectionLabel(text: "Earlier") }
                rows(earlier, last: true)
            }
        }
        #if os(iOS)
        .alert("Something went wrong", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        #endif
    }

    @ViewBuilder private func rows(_ items: [NetworkActivity.Item], last: Bool) -> some View {
        ForEach(items) { item in
            Button { open(item.threadRoot) } label: {
                row(item)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the replies")
            if !(last && item.id == items.last?.id) { CastDivider() }
        }
    }

    @ViewBuilder private func row(_ item: NetworkActivity.Item) -> some View {
        #if os(iOS)
        phoneRow(item)
        #else
        macRow(item)
        #endif
    }

    #if os(iOS)
    /// X's row: a like names its likers over your post, and a reply or mention shows their words. Your
    /// post's first picture sits at the trailing edge: the liked post, the post a reply answers, or for a
    /// mention, theirs.
    @ViewBuilder private func phoneRow(_ item: NetworkActivity.Item) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(item.when))
        if item.isLike, let likers = item.likers, !likers.isEmpty {
            let names = likers.map { model.handle(for: $0.fid, named: $0.username) }
            let header = NetworkLikeRow.header(names: names, count: item.count ?? names.count,
                                               reply: item.parent != nil || item.post.parent != nil)
            let picture = model.firstPicture(of: item.post)
            NetworkActivityRow(glyph: "heart.fill",
                               people: zip(likers, names).map { NetworkActivityRow.Person(url: avatar(for: $0.fid), handle: $1) },
                               sentence: title(header), date: date,
                               line: NetworkLikeRow.caption(of: item.post, pictureShown: picture != nil),
                               picture: picture)
        } else {
            let reply = item.kind == "reply"
            let handle = model.handle(for: item.post.fid)
            let text = item.post.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = reply ? item.parent.flatMap { $0.deleted ? nil : $0 } : item.post
            NetworkActivityRow(glyph: reply ? "arrowshape.turn.up.left.fill" : "at",
                               people: [.init(url: avatar(for: item.post.fid), handle: handle)],
                               sentence: Text("\(Text(verbatim: handle).font(FatlineStyle.bodyStrong))\(Text(reply ? " replied" : " mentioned you").font(FatlineStyle.body))"),
                               date: date,
                               line: text.isEmpty ? NetworkLikeRow.summary(of: item.post) : text, lineIsTheirs: true,
                               picture: shown.flatMap { model.firstPicture(of: $0) })
        }
    }

    /// A member's picture, from the network's own host.
    private func avatar(for fid: UInt64) -> URL? {
        guard let link = model.members.first(where: { $0.fid == fid })?.avatar, let host = model.selectedHost else { return nil }
        return FeedCast.networkMediaURL(link, host: host)
    }
    #endif

    @ViewBuilder private func macRow(_ item: NetworkActivity.Item) -> some View {
        if item.isLike, let newest = item.likers?.first {
            // The newest liker's picture, at the newest like's time, over your post's text on one line.
            let names = (item.likers ?? []).map { model.handle(for: $0.fid, named: $0.username) }
            let header = NetworkLikeRow.header(names: names, count: item.count ?? names.count,
                                               reply: item.parent != nil || item.post.parent != nil)
            CastRow(cast: FeedCast(hash: item.post.hash, fid: newest.fid, time: item.when, text: "",
                                   avatar: model.members.first { $0.fid == newest.fid }?.avatar, mediaHost: model.selectedHost),
                    handle: names.first ?? "", badge: "heart.fill", title: title(header),
                    summary: NetworkLikeRow.summary(of: item.post))
        } else {
            CastRow(cast: cast(for: item), handle: model.handle(for: item.post.fid),
                    action: item.kind == "reply" ? "replied" : "mentioned you",
                    badge: item.kind == "reply" ? "arrowshape.turn.up.left.fill" : "at")
        }
    }

    /// One text, names bold, so a long header wraps as a sentence.
    private func title(_ pieces: [NetworkLikeRow.Piece]) -> Text {
        pieces.reduce(Text(verbatim: "")) { text, piece in
            Text("\(text)\(Text(verbatim: piece.text).font(piece.isName ? FatlineStyle.bodyStrong : FatlineStyle.body))")
        }
    }

    /// For an admin: how many are waiting to join, which opens the admin pages in the browser.
    private func requests(_ waiting: Int) -> some View {
        Button(action: manage) {
            HStack(spacing: FatlineStyle.avatarGap) {
                NetworkMark(name: membership.title, icon: membership.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(waiting == 1 ? "1 request to join" : "\(waiting) requests to join")
                        .font(FatlineStyle.bodyStrong)
                    Text("Manage Network")
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(FatlineStyle.metaStrong)
                    .foregroundStyle(FatlineStyle.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FatlineStyle.gutter)
            .padding(.vertical, FatlineStyle.rowPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(opening)
        .accessibilityElement(children: .combine)
        #if os(iOS)
        .accessibilityHint("Opens the admin pages in Safari")
        #else
        .accessibilityHint("Opens the admin pages in your browser")
        #endif
        .accessibilityIdentifier("activity-requests")
    }

    /// The post, quoting the one it answers.
    private func cast(for item: NetworkActivity.Item) -> FeedCast {
        var cast = model.cast(for: item.post)
        if let parent = item.parent, !parent.deleted {
            cast.quote = FeedCast.Quote(fid: parent.fid, handle: model.handle(for: parent.fid), text: parent.text)
        }
        return cast
    }

    /// The one-time link to the admin pages. A failure shows as the Mac's toast, or an alert on iPhone.
    private func manage() {
        opening = true
        Task {
            do {
                openURL(try await model.adminLink())
            } catch {
                #if os(macOS)
                model.toast = error.localizedDescription
                #else
                problem = error.localizedDescription
                #endif
            }
            opening = false
        }
    }
}
