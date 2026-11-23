import SwiftUI

extension View {
    /// The composers' header, the same as today's sheets: the glass × at the leading edge, where the post
    /// goes in the middle, and Post as a capsule at the trailing edge, both the system's 44 points tall.
    /// The content goes inside a NavigationStack.
    func composerHeader<Title: View>(post: String, canPost: Bool, working: Bool, canCancel: Bool,
                                     cancel: @escaping () -> Void, send: @escaping () -> Void,
                                     @ViewBuilder title: @escaping () -> Title) -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: cancel)
                        .disabled(!canCancel)
                        .accessibilityIdentifier("composer-cancel")
                }
                ToolbarItem(placement: .principal) {
                    title()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        Text(post)
                            // The tint's own ink, which reads in dark too, and grey on plain glass while off.
                            .foregroundStyle(canPost ? FatlineStyle.actionInk : FatlineStyle.secondary)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(FatlineStyle.action)
                    .disabled(!canPost)
                    .opacity(working ? 0.6 : 1) // layout-ok: dimmed while posting, as FatlinePrimaryButton does
                    .accessibilityIdentifier("network-post")
                }
            }
    }
}

/// Where a post goes, in the composer's header: the network's mark, or Farcaster's, and its name.
struct ComposerTitle<Mark: View>: View {
    let name: String
    let label: String
    @ViewBuilder let mark: () -> Mark

    /// The mark beside the 17-point title, as on the canvas.
    static var markSize: CGFloat { 20 } // layout-ok: the mark beside the bar's 17-point title, as on the canvas

    var body: some View {
        HStack(spacing: FatlineStyle.itemGap) {
            mark()
            Text(verbatim: name)
                .font(.headline)
                .foregroundStyle(FatlineStyle.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The members an @name could be, above the composer's bar: each with their picture, name, and
/// @username, and a tap puts in the username.
struct MentionList: View {
    let members: [NetworkMember]
    let host: String
    let pick: (NetworkMember) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FatlineDivider()
            ForEach(members) { member in
                if member.id != members.first?.id { TextColumnDivider() }
                Button { pick(member) } label: { row(member) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mention-\(member.username)")
            }
        }
        .background(FatlineStyle.paper)
    }

    private func row(_ member: NetworkMember) -> some View {
        let name = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: FatlineStyle.avatarGap) {
            CastAvatar(url: member.avatar.flatMap { FeedCast.networkMediaURL($0, host: host) }, handle: member.username)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name.isEmpty ? member.username : name)
                    .font(FatlineStyle.bodyStrong)
                    .lineLimit(1)
                if !name.isEmpty {
                    Text(verbatim: "@\(member.username)")
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(FatlineStyle.ink)
        .padding(.horizontal, FatlineStyle.gutter)
        .frame(minHeight: FatlineStyle.listRowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Puts in @\(member.username)")
    }
}
