import SwiftUI

// The floating bar and the parts every screen under it shares: the header with a mark where avatars
// sit and a title where post text starts, the title's glass capsule once it has scrolled away, and
// the rows of Settings. From the canvas's iPhone redesign page.

/// Where the floating bar goes. Farcaster, and a network that hasn't let you in, have no Activity.
enum FatlineTab: Hashable {
    case home, activity, settings
}

extension EnvironmentValues {
    /// How much of the bottom of a tab's first screen the floating bar takes, above the safe area.
    @Entry var barReserve: CGFloat = 0
}

/// A feed with the floating bar over it. Each tab's first screen takes `underBar()`, so it scrolls
/// under the bar and stops a gutter above it. A safe area set out here wouldn't reach a screen
/// inside a navigation stack.
struct FatlineTabShell<Content: View>: View {
    @Binding var tab: FatlineTab
    let tabs: [FatlineTab]
    /// False while a tab has pushed a screen, which then has the whole height.
    let showsBar: Bool
    var activityIsNew = false
    /// Your picture and handle, which stand for Settings.
    let picture: URL?
    let handle: String
    /// Nil leaves the plus out.
    let compose: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // The bar sits lower than the safe area, as a system bar does.
            let below = proxy.safeAreaInsets.bottom
            let reach = max(0, FatlineStyle.barBottom + FatlineStyle.barHeight - below)
            content()
                .environment(\.barReserve, reach + FatlineStyle.gutter)
                .overlay(alignment: .bottom) {
                    if showsBar {
                        FatlineTabBar(tab: $tab, tabs: tabs, activityIsNew: activityIsNew, picture: picture, handle: handle, compose: compose)
                            .padding(.horizontal, FatlineStyle.gutter)
                            .padding(.bottom, FatlineStyle.barBottom - below)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsBar)
        }
        // A keyboard doesn't lift the bar.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

/// Leaves room for the floating bar at the bottom of a tab's first screen.
private struct UnderBar: ViewModifier {
    @Environment(\.barReserve) private var reserve

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: reserve) }
    }
}

extension View {
    func underBar() -> some View { modifier(UnderBar()) }

    /// One tab's screen. It stays in place while another tab shows, so coming back finds it as it was.
    func tabPage(_ page: FatlineTab, showing: FatlineTab) -> some View {
        opacity(page == showing ? 1 : 0)
            .allowsHitTesting(page == showing)
            .accessibilityHidden(page != showing)
    }
}

/// The glass capsule of tabs, and the plus beside it. Glyphs only, each with its name for VoiceOver
/// and for a long press at the largest text sizes.
struct FatlineTabBar: View {
    @Binding var tab: FatlineTab
    let tabs: [FatlineTab]
    let activityIsNew: Bool
    let picture: URL?
    let handle: String
    let compose: (() -> Void)?

    var body: some View {
        HStack(spacing: FatlineStyle.gutter) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { item in
                    Button {
                        guard tab != item else { return }
                        Platform.haptic(.pick)
                        tab = item
                    } label: {
                        glyph(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(tab == item ? FatlineStyle.selection : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(item))
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityShowsLargeContentViewer {
                        Label(name(item), systemImage: symbol(item, selected: false))
                    }
                    .accessibilityIdentifier(identifier(item))
                }
            }
            .padding(FatlineStyle.barInset)
            .frame(height: FatlineStyle.barHeight)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
            if let compose {
                PlusButton(action: compose)
            }
        }
        .foregroundStyle(FatlineStyle.ink)
    }

    @ViewBuilder private func glyph(_ item: FatlineTab) -> some View {
        let selected = tab == item
        switch item {
        case .home:
            Image(systemName: symbol(item, selected: selected)).font(FatlineStyle.tabGlyph)
        case .activity:
            Image(systemName: symbol(item, selected: selected))
                .font(FatlineStyle.tabGlyph)
                .unreadDot(activityIsNew && !selected, inset: -3) // layout-ok: the dot sits over the tray's corner, as on a mark
        case .settings:
            // Your picture, with a ring around it while Settings shows.
            CastAvatar(url: picture, handle: handle, size: FatlineStyle.barPicture)
                .padding(FatlineStyle.barInset)
                .overlay {
                    if selected { Circle().strokeBorder(FatlineStyle.ink, lineWidth: FatlineStyle.unreadRing) }
                }
        }
    }

    private func symbol(_ item: FatlineTab, selected: Bool) -> String {
        switch item {
        case .home: selected ? "house.fill" : "house"
        case .activity: selected ? "tray.fill" : "tray"
        case .settings: "person.crop.circle"
        }
    }

    private func name(_ item: FatlineTab) -> String {
        switch item {
        case .home: "Home"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    private func label(_ item: FatlineTab) -> String {
        item == .activity && activityIsNew ? "Activity, new replies" : name(item)
    }

    /// Activity and Settings keep the names their buttons had before the bar.
    private func identifier(_ item: FatlineTab) -> String {
        switch item {
        case .home: "tab-home"
        case .activity: "network-activity"
        case .settings: "settings"
        }
    }
}

/// The round plus beside the tabs: lit from above, with one soft shadow under it.
struct PlusButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlusFace()
        }
        .buttonStyle(FloatingButtonStyle())
        .accessibilityLabel("Compose")
        .accessibilityIdentifier("compose")
    }
}

/// Stays solid while pressed. The plus floats over the feed, and the plain style's fade let the text
/// underneath show through it. The haptic plays on touch-down, ahead of the composer opening on release.
struct FloatingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Platform.haptic(.tap) }
            }
    }
}

/// The top of Home, Activity, and Settings: a mark or picture where avatars sit, the title where post
/// text starts, and one line under it. With an action it's a button with a chevron, and a dot while
/// there's news elsewhere.
struct ScreenHeader<Lead: View>: View {
    let title: String
    var meta: String? = nil
    var news = false
    /// What VoiceOver reads for the button, such as "Pine Street. Switch network".
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let lead: () -> Lead

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(actionLabel ?? title)
                .accessibilityHint("Shows your networks")
                .accessibilityIdentifier("network-title")
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: FatlineStyle.avatarGap) {
            lead()
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: FatlineStyle.itemGap) {
                    Text(verbatim: title)
                        .font(FatlineStyle.tabTitle)
                        .tracking(-0.4)
                        .lineLimit(1)
                    if action != nil { TitleChevron(news: news) }
                }
                if let meta {
                    Text(verbatim: meta)
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(FatlineStyle.ink)
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.screenTop)
        .contentShape(.rect)
        // Like a system bar's title, it stops growing at the largest regular size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The chevron after a title that switches networks, and the dot while another network has news.
private struct TitleChevron: View {
    let news: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(FatlineStyle.metaStrong)
            .foregroundStyle(FatlineStyle.secondary)
        if news {
            Circle()
                .fill(FatlineStyle.ink)
                .frame(width: FatlineStyle.unreadDot, height: FatlineStyle.unreadDot)
        }
    }
}

/// How far a screen has scrolled: at the top, moving, or past its header.
enum ScrollStage: Int {
    case top, moving, past
}

extension View {
    /// Reports how far a scroll view has gone, only when the stage changes.
    func scrollStage(_ stage: Binding<ScrollStage>) -> some View {
        onScrollGeometryChange(for: ScrollStage.self) { geometry in
            let y = geometry.contentOffset.y + geometry.contentInsets.top
            // The header's title has left once its row has, a little before the whole header.
            return y > FatlineStyle.headerHeight ? .past : y > FatlineStyle.castGap ? .moving : .top
        } action: { _, new in
            stage.wrappedValue = new
        }
    }

    /// Over a scrolling screen: the paper fades in under the status bar once it moves.
    func scrollFade(_ stage: ScrollStage) -> some View {
        overlay(alignment: .top) {
            // Solid over the status bar, which is about half of this, then clear by the end.
            LinearGradient(stops: [
                .init(color: FatlineStyle.paper, location: 0),
                .init(color: FatlineStyle.paper, location: 0.5),
                .init(color: FatlineStyle.paper.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: FatlineStyle.barHeight)
                .ignoresSafeArea(edges: .top)
                .opacity(stage == .top ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: stage)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Past the header, its title comes back as a glass capsule in the same place.
    func titleCapsule<Lead: View>(
        _ title: String, news: Bool, label: String, shown: Bool, action: (() -> Void)?, @ViewBuilder lead: @escaping () -> Lead
    ) -> some View {
        overlay(alignment: .topLeading) {
            TitleCapsule(title: title, news: news, label: label, shown: shown, action: action, lead: lead)
        }
    }
}

private struct TitleCapsule<Lead: View>: View {
    let title: String
    let news: Bool
    let label: String
    let shown: Bool
    let action: (() -> Void)?
    @ViewBuilder let lead: () -> Lead

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if shown {
                Button { action?() } label: {
                    HStack(spacing: FatlineStyle.avatarGap) {
                        lead()
                            .frame(width: FatlineStyle.titleCapsuleMark, height: FatlineStyle.titleCapsuleMark)
                        HStack(spacing: FatlineStyle.itemGap) {
                            Text(verbatim: title)
                                .font(FatlineStyle.bodyStrong)
                                .lineLimit(1)
                            if action != nil { TitleChevron(news: news) }
                        }
                    }
                    .foregroundStyle(FatlineStyle.ink)
                    // The mark sits 8 in, which puts the name on the text column.
                    .padding(.leading, FatlineStyle.itemGap)
                    .padding(.trailing, FatlineStyle.gutter)
                    .frame(height: FatlineStyle.titleCapsuleHeight)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
                .glassEffect(.regular, in: .capsule)
                .padding(.leading, FatlineStyle.gutter)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint(action == nil ? "" : "Shows your networks")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
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
/// chevron or another symbol.
struct SettingsRow: View {
    let symbol: String
    let title: String
    var value: String? = nil
    /// Nil leaves the trailing symbol out, for a row that acts in place.
    var trailing: String? = "chevron.right"
    var color = FatlineStyle.ink

    var body: some View {
        HStack(spacing: FatlineStyle.avatarGap) {
            Image(systemName: symbol)
                .font(FatlineStyle.rowGlyph)
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            Text(title)
                .font(FatlineStyle.body)
                .lineLimit(1)
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
                    .foregroundStyle(FatlineStyle.secondary)
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
