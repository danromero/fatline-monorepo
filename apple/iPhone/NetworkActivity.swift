import SwiftUI

/// Replies to your posts, mentions of you, and likes on your posts, the second tab, under a small
/// centered Activity. The rows are X's, with your post's picture at the trailing edge; the Mac keeps
/// its own and doesn't show likes yet. Likes don't add to the tab's count.
struct NetworkActivityView: View {
    let membership: NetworkMembership
    /// True while this tab is the one showing. Reading Activity marks it seen, so it only reads then.
    let showing: Bool
    let open: (NetworkPost) -> Void

    @Environment(NetworkModel.self) private var model
    @State private var activity = NetworkActivityState()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                CastDivider()
                NetworkActivityList(activity: activity, model: model, membership: membership, open: open)
            }
        }
        .refreshable { await activity.load(model, admin: membership.isAdmin) }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Activity")
        .task(id: showing) {
            guard showing else { return }
            // Its replies and mentions come off the badge.
            PushCenter.shared.activityOpened(membership.host)
            activity.begin(model)
            await activity.load(model, admin: membership.isAdmin)
        }
    }
}
