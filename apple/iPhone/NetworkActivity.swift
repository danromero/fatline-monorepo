import SwiftUI

/// Replies to your posts and mentions of you, in the bar's second tab, under the network's mark and
/// the title. The rows are the same as the Mac's.
struct NetworkActivityView: View {
    let membership: NetworkMembership
    /// True while this tab is the one showing. Reading Activity marks it seen, so it only reads then.
    let showing: Bool
    let open: (NetworkPost) -> Void

    @Environment(NetworkModel.self) private var model
    @State private var activity = NetworkActivityState()
    @State private var stage = ScrollStage.top

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ScreenHeader(title: "Activity", meta: membership.title) {
                    NetworkMark(name: membership.title, icon: membership.icon)
                }
                CastDivider()
                NetworkActivityList(activity: activity, model: model, membership: membership, open: open)
            }
        }
        .scrollStage($stage)
        .refreshable { await activity.load(model, admin: membership.isAdmin) }
        .scrollFade(stage)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .task(id: showing) {
            guard showing else { return }
            activity.begin(model)
            await activity.load(model, admin: membership.isAdmin)
        }
    }
}
