import SwiftUI

/// A network that hasn't let you in yet: an empty dashed tile where its mark would be.
struct NetworkWaitingMark: View {
    var size = FatlineStyle.avatarSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * FatlineStyle.markRadiusRatio, style: .continuous)
            .strokeBorder(FatlineStyle.outline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Farcaster and each network, from the title: a mark, the name, and the address under a network's
/// own name. The one showing sits in a capsule with a check, a dot marks one with news, and a
/// network that hasn't let you in yet shows only its address, dimmed. Add Network is last, under a rule.
struct NetworksSheet: View {
    /// Closes the sheet and starts joining another network.
    let addNetwork: () -> Void

    @Environment(NetworkModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    farcaster
                    ForEach(model.memberships) { membership in
                        row(membership)
                    }
                    FatlineDivider(inset: FatlineStyle.gutter)
                        .padding(.vertical, FatlineStyle.itemGap)
                    addRow
                }
                .padding(.horizontal, FatlineStyle.sheetRowInset)
                .padding(.bottom, FatlineStyle.sheetRowInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, FatlineStyle.itemGap)
        .foregroundStyle(FatlineStyle.ink)
        .presentationDetents([.height(FatlineStyle.itemGap + FatlineStyle.headerHeight + max(height, FatlineStyle.sheetRowHeight))])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        Text("Networks")
            .font(FatlineStyle.bodyStrong)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, minHeight: FatlineStyle.headerHeight)
            .overlay(alignment: .trailing) {
                Button { dismiss() } label: {
                    Text("Done")
                        .font(FatlineStyle.body)
                        .padding(.horizontal, FatlineStyle.groupGap)
                        .frame(minHeight: FatlineStyle.buttonHitHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The label's 12-point inset puts Done's edge where the rows' checks end.
                .padding(.trailing, FatlineStyle.sheetRowInset + FatlineStyle.gutter - FatlineStyle.groupGap)
            }
            // Like a system bar, it stops growing before the title runs into Done.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var farcaster: some View {
        let showing = model.selectedHost == nil
        return Button { choose(nil) } label: {
            HStack(spacing: FatlineStyle.groupGap) {
                FarcasterMark()
                Text("Farcaster")
                    .font(FatlineStyle.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showing { check }
            }
            .sheetRow(showing: showing)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Farcaster")
        .accessibilityAddTraits(showing ? .isSelected : [])
    }

    private func row(_ membership: NetworkMembership) -> some View {
        let showing = membership.host == model.selectedHost
        let approved = membership.status == .approved
        let news = approved && model.hasNews(membership.host)
        let waiting = membership.status == .pending ? "Waiting" : "Not approved"
        return Button { choose(membership.host) } label: {
            HStack(spacing: FatlineStyle.groupGap) {
                if approved {
                    NetworkMark(name: membership.title, icon: membership.icon, filled: showing)
                } else {
                    NetworkWaitingMark()
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: approved ? membership.title : membership.host)
                        .font(news ? FatlineStyle.bodyStrong : FatlineStyle.body)
                        .lineLimit(1)
                    // The address under a network's own name, so a network can't pass for another.
                    if approved, membership.name != nil {
                        Text(verbatim: membership.host)
                            .font(FatlineStyle.meta)
                            .foregroundStyle(FatlineStyle.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showing {
                    check
                } else if news {
                    Circle()
                        .fill(FatlineStyle.ink)
                        .frame(width: FatlineStyle.unreadDot, height: FatlineStyle.unreadDot)
                } else if !approved {
                    Text(waiting).font(FatlineStyle.meta)
                }
            }
            .foregroundStyle(approved ? FatlineStyle.ink : FatlineStyle.secondary)
            .sheetRow(showing: showing)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(approved
            ? membership.label + (news ? ", news" : "")
            : "\(membership.host), \(waiting)")
        .accessibilityAddTraits(showing ? .isSelected : [])
    }

    /// An outlined tile with a plus where a mark goes, and Add Network.
    private var addRow: some View {
        Button {
            Platform.haptic(.tap)
            addNetwork()
        } label: {
            HStack(spacing: FatlineStyle.groupGap) {
                RoundedRectangle(cornerRadius: FatlineStyle.avatarSize * FatlineStyle.markRadiusRatio, style: .continuous)
                    .strokeBorder(FatlineStyle.outline, lineWidth: 1)
                    .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                    .overlay {
                        Image(systemName: "plus")
                            .font(FatlineStyle.markGlyph)
                    }
                    .accessibilityHidden(true)
                Text("Add Network")
                    .font(FatlineStyle.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheetRow(showing: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add-network")
    }

    private var check: some View {
        Image(systemName: "checkmark")
            .font(FatlineStyle.markGlyph)
            .foregroundStyle(FatlineStyle.ink)
            .accessibilityHidden(true)
    }

    private func choose(_ host: String?) {
        Platform.haptic(.pick)
        model.select(host)
        dismiss()
    }
}

private extension View {
    /// A row in the sheet, with a capsule behind the network that's showing.
    func sheetRow(showing: Bool) -> some View {
        padding(.horizontal, FatlineStyle.gutter)
            .frame(maxWidth: .infinity, minHeight: FatlineStyle.sheetRowHeight)
            .background(showing ? FatlineStyle.selection : .clear, in: .capsule)
            .contentShape(.capsule)
    }
}
