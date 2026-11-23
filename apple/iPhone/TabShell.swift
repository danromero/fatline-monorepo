import SwiftUI

// The parts every tab shares. The tab bar and the top bar are the system's. A feed's top bar holds the
// network's mark, which opens the network menu: the networks, Add Network, and Settings. Compose is a
// glass circle at the bottom right, beside the tab bar, on Home and Activity.

/// The tabs. Farcaster, and a network that hasn't let you in, have no Activity.
enum FatlineTab: Hashable {
    case home, activity
}

/// The composer opens by zooming out of Compose: the button is the source, the sheet the target.
enum ComposeZoom {
    static let id = "compose"
}

/// A feed's top bar: its network's mark in the system's round glass button at the leading edge, with a
/// dot while another network has news. The mark opens the network menu. The title is the screen's own
/// `navigationTitle`, inline and centered.
struct FeedBar<Mark: View>: ToolbarContent {
    /// The network's name, which a long press on the mark shows at the largest text sizes.
    let name: String
    /// What VoiceOver reads for the mark, such as "Pine Street. Networks and Settings".
    let label: String
    let addNetwork: () -> Void
    let openSettings: () -> Void
    @ViewBuilder let mark: () -> Mark

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // The mark sits in the bar's glass like a glyph, so the system sizes the button around it.
            NetworkMenu(addNetwork: addNetwork, openSettings: openSettings) {
                mark()
                    .frame(width: FatlineStyle.toolbarMark, height: FatlineStyle.toolbarMark)
            }
            // A menu's label otherwise gets a text button's capsule. As a plain button it gets the round glass.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint("Shows your networks and Settings")
            .accessibilityIdentifier("network-title")
            // Without this, the large content viewer shows the mark's letter.
            .accessibilityShowsLargeContentViewer { Text(verbatim: name) }
        }
    }
}

/// The system's menu from the mark, which grows out of its glass button: Farcaster and each network,
/// with a check on the one showing, then Add Network and Settings. Under a network's own name is its
/// address, so a network can't pass for another, and "New posts" while it has news. A network that
/// hasn't let you in shows its address and where it stands: Waiting, Not approved, or Removed.
struct NetworkMenu<MenuLabel: View>: View {
    let addNetwork: () -> Void
    let openSettings: () -> Void
    @ViewBuilder let label: () -> MenuLabel

    @Environment(NetworkModel.self) private var model

    var body: some View {
        Menu {
            Section {
                Toggle(isOn: showing(nil)) { Text("Farcaster") }
                ForEach(model.memberships) { membership in
                    Toggle(isOn: showing(membership.host)) {
                        Text(verbatim: membership.status == .approved ? membership.title : membership.host)
                        Text(verbatim: detail(membership))
                    }
                }
            }
            Section {
                Button("Add Network", systemImage: "plus") {
                    Platform.haptic(.tap)
                    addNetwork()
                }
                .accessibilityIdentifier("add-network")
                Button("Settings", systemImage: "gearshape", action: openSettings)
                    .accessibilityIdentifier("settings")
            }
        } label: {
            label()
        }
    }

    /// On for the network showing. Turning one on shows it; turning the one showing off does nothing.
    private func showing(_ host: String?) -> Binding<Bool> {
        Binding(get: { model.selectedHost == host }, set: { on in
            guard on, model.selectedHost != host else { return }
            Platform.haptic(.pick)
            model.select(host)
        })
    }

    private func detail(_ membership: NetworkMembership) -> String {
        guard membership.status == .approved else { return membership.standing ?? "" }
        return model.hasNews(membership.host) ? "\(membership.host) · New posts" : membership.host
    }
}

/// Compose: a glass circle at the bottom right, the tab bar's height on its bottom edge, as Photos sets
/// Search beside its tab bar. The composer zooms out of it.
struct ComposeButton: View {
    let zoom: Namespace.ID
    let action: () -> Void

    var body: some View {
        // Fills the screen without taking touches, so the circle can sit from the screen's own edges as the tab bar does.
        ZStack(alignment: .bottomTrailing) {
            Color.clear.allowsHitTesting(false)
            Button {
                Platform.haptic(.tap)
                action()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(FatlineStyle.composeGlyph)
                    .foregroundStyle(FatlineStyle.ink)
                    .frame(width: FatlineStyle.tabBarHeight, height: FatlineStyle.tabBarHeight)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .matchedTransitionSource(id: ComposeZoom.id, in: zoom)
            .accessibilityLabel("Compose")
            .accessibilityIdentifier("compose")
            // Its name under the glyph, as the tabs show theirs.
            .accessibilityShowsLargeContentViewer { Label("Compose", systemImage: "square.and.pencil") }
            .padding(.trailing, FatlineStyle.tabBarInset)
            .padding(.bottom, FatlineStyle.tabBarInset)
        }
        .ignoresSafeArea(.container)
    }
}

/// Settings as a sheet from the network menu, with its own navigation and Done.
struct SettingsSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}

/// The first row of Settings: your picture where avatars sit, your name on the text column, and where
/// you are under it, so a network can't pass for another.
struct IdentityRow<Lead: View>: View {
    let title: String
    let meta: String
    @ViewBuilder let lead: () -> Lead

    var body: some View {
        HStack(spacing: FatlineStyle.avatarGap) {
            lead()
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(FatlineStyle.bodyStrong)
                    .lineLimit(1)
                Text(verbatim: meta)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(FatlineStyle.ink)
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .accessibilityElement(children: .combine)
    }
}

/// How a toast comes and goes: it fades in while rising a little into place, and fades out the same
/// way, sinking back, in less time. With Reduce Motion it only fades.
private struct ToastPresence: ViewModifier {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : FatlineStyle.toastScale, anchor: .bottom)
            .offset(y: shown || reduceMotion ? 0 : FatlineStyle.itemGap)
            .accessibilityHidden(!shown)
            // Quick in, quicker out.
            .animation(shown ? .snappy(duration: 0.28) : .easeOut(duration: 0.18), value: shown)
    }
}

extension View {
    func toastPresence(_ shown: Bool) -> some View { modifier(ToastPresence(shown: shown)) }
}

extension AnyTransition {
    /// A toast's first appearance, which matches `toastPresence`.
    static var toast: AnyTransition {
        .opacity.combined(with: .scale(scale: FatlineStyle.toastScale, anchor: .bottom)).combined(with: .offset(y: FatlineStyle.itemGap))
    }
}

/// A row in Settings: a glyph where avatars sit, its name on the text column, then a value and a
/// chevron or another symbol. At large text sizes the name wraps and the row grows.
struct SettingsRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    /// Nil leaves the trailing symbol out, for a row that acts in place.
    var trailing: String? = "chevron.right"
    var color = FatlineStyle.ink
    /// The ink for a choice's check; secondary for a chevron or an arrow.
    var trailingColor = FatlineStyle.secondary

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // One line centers on the row. At the largest sizes the name can wrap, so the glyph, value and
        // chevron sit on its first line instead.
        HStack(alignment: typeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: FatlineStyle.avatarGap) {
            Image(systemName: symbol)
                .font(FatlineStyle.rowGlyph)
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            Text(title)
                .font(FatlineStyle.body)
                .fixedSize(horizontal: false, vertical: true)
                // Only a wrapped name reaches this padding, as on the identity row; one line sits inside the row's height.
                .padding(.vertical, FatlineStyle.rowPadding)
            Spacer(minLength: FatlineStyle.itemGap)
            if let value {
                Text(value)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .lineLimit(1)
            }
            if let trailing {
                Image(systemName: trailing)
                    .font(FatlineStyle.metaStrong)
                    .foregroundStyle(trailingColor)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, FatlineStyle.gutter)
        .frame(minHeight: FatlineStyle.listRowHeight)
        .contentShape(.rect)
    }
}

/// The rule between rows that have a glyph or a mark: from the text column to the gutter.
struct TextColumnDivider: View {
    var body: some View {
        FatlineDivider(inset: FatlineStyle.gutter)
            .padding(.leading, FatlineStyle.textColumn - FatlineStyle.gutter)
    }
}
