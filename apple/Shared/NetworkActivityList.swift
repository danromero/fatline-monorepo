import SwiftUI

/// What Activity has read, for one visit: the replies and mentions, where New ends, and for an admin
/// how many are waiting to join.
@MainActor
@Observable
final class NetworkActivityState {
    private(set) var items: [NetworkActivity.Item] = []
    private(set) var loaded = false
    private(set) var failure: String?
    /// The newest item Activity had shown when this visit began. Items after it are New.
    private(set) var seenBefore: Int64?
    private(set) var waiting = 0

    /// A visit begins. Call it before `load`, which marks everything seen.
    func begin(_ model: NetworkModel) {
        seenBefore = model.activitySeen
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
        seenBefore.map { item.post.time > $0 } ?? false
    }
}

/// Activity's rows, in both apps: what arrived since the last look under New, and the rest under
/// Earlier. Each row opens the replies it's part of, a reply shows the post it answers in a quiet
/// card, and an admin sees requests to join first. It goes inside the screen's own scrolling stack.
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
        ForEach(items, id: \.post.hash) { item in
            Button { open(item.threadRoot) } label: {
                CastRow(cast: cast(for: item), handle: model.handle(for: item.post.fid),
                        action: item.kind == "reply" ? "replied" : "mentioned you",
                        badge: item.kind == "reply" ? "arrowshape.turn.up.left.fill" : "at")
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the replies")
            if !(last && item.post.hash == items.last?.post.hash) { CastDivider() }
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
