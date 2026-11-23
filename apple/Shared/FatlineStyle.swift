import SwiftUI

enum FatlineStyle {
    static let paper = adaptive(light: 0xFDFBF7, dark: 0x121B16)
    static let ink = adaptive(light: 0x0A2F1D, dark: 0xF0F1E9)
    static let secondary = adaptive(light: 0x54635A, dark: 0xAAB8AF)
    static let action = adaptive(light: 0x0A2F1D, dark: 0xC0D8C7)
    static let actionInk = adaptive(light: 0xFDFBF7, dark: 0x0A2F1D)
    #if os(macOS)
    // Increase Contrast darkens the two colors that only barely differ from the paper.
    static let quiet = adaptive(light: 0xECEFE8, dark: 0x25342B, contrastLight: 0xD3DAD0, contrastDark: 0x3B4D41)
    static let line = adaptive(light: 0xDFE4DC, dark: 0x3A493F, contrastLight: 0x7E8B82, contrastDark: 0x8A9A90)
    static let outline = adaptive(light: 0xC5CEC6, dark: 0x506256, contrastLight: 0x7E8B82, contrastDark: 0x8A9A90)
    static let danger = Color(nsColor: .systemRed)
    #else
    static let quiet = adaptive(light: 0xECEFE8, dark: 0x25342B)
    static let line = adaptive(light: 0xDFE4DC, dark: 0x3A493F)
    static let outline = adaptive(light: 0xC5CEC6, dark: 0x506256)
    static let danger = Color(uiColor: .systemRed)
    #endif

    /// The top of the Mac's plus, which is lit from above and ends in `action`.
    static let actionLit = adaptive(light: 0x164631, dark: 0xD6E7DB)

    enum Weight: String {
        case regular = "Regular"
        case semibold = "SemiBold"
    }

    #if os(macOS)
    // Type scale: 28, 22, 14, and 12 only. The title bar draws titles in the system font.
    static let bodySize: CGFloat = 14
    static let display = font(28, .semibold, relativeTo: .largeTitle)
    static let screenTitle = font(22, .semibold, relativeTo: .title2)
    static let body = font(bodySize)
    static let bodyStrong = font(bodySize, .semibold)
    static let meta = font(12, relativeTo: .footnote)
    static let metaStrong = font(12, .semibold, relativeTo: .footnote)
    static let bodyLineSpacing: CGFloat = 3 // Puts 14-point Inter on 20-point lines.
    static let plusGlyph = Font.system(size: 20, weight: .semibold)

    static let avatarSize: CGFloat = 28
    static let avatarGap: CGFloat = 10
    static let avatarTopInset: CGFloat = 1
    static let rowPadding: CGFloat = 11
    static let headerHeight: CGFloat = 52
    static let headerGap: CGFloat = 0
    /// The feed stops growing at this width and stays centered.
    static let columnMaxWidth: CGFloat = 620
    static let compactButtonHeight: CGFloat = 30
    static let regularButtonHeight: CGFloat = 40
    static let buttonHitHeight: CGFloat = 0
    static let outlineButtonHeight: CGFloat = 32
    static let screenGutter: CGFloat = 32
    static let screenTop: CGFloat = 24
    static let screenBottom: CGFloat = 28
    /// Link cards and pictures in posts.
    static let cardRadius: CGFloat = 10
    // Network marks: a rounded square with the network's first letter.
    static let markRadiusRatio: CGFloat = 0.27
    static let actionIconGap: CGFloat = 6
    /// The floating plus over a feed.
    static let plusSize: CGFloat = 48
    /// The badge on an Activity row's avatar, and how far it hangs past the avatar's corner.
    static let badgeSize: CGFloat = 16
    static let badgeOverhang: CGFloat = 4
    static let badgeGlyph = Font.system(size: 8, weight: .bold)
    static let floatShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.4) : NSColor(srgbRed: 10 / 255, green: 47 / 255, blue: 29 / 255, alpha: 0.2)
    })
    #else
    // Type scale: 34, 24, 16, and 13 only. The titles at the top of Home, Activity, and Settings are
    // the system's large titles, in the system font.
    static let bodySize: CGFloat = 16
    static let display = font(34, .semibold, relativeTo: .largeTitle)
    static let screenTitle = font(24, .semibold, relativeTo: .title2)
    static let body = font(bodySize)
    static let bodyStrong = font(bodySize, .semibold)
    static let meta = font(13, relativeTo: .footnote)
    static let metaStrong = font(13, .semibold, relativeTo: .footnote)
    static let bodyLineSpacing: CGFloat = 2
    /// The glyph at the start of a row in Settings, in the avatar's column.
    static let rowGlyph = Font.system(size: 20, weight: .regular)

    static let avatarSize: CGFloat = 40
    static let avatarGap: CGFloat = 12
    static let avatarTopInset: CGFloat = 4 // Puts the avatar's top just above the username's letters.
    static let rowPadding: CGFloat = 12
    static let headerHeight: CGFloat = 44
    static let headerGap: CGFloat = 10
    static let compactButtonHeight: CGFloat = 32
    static let regularButtonHeight: CGFloat = 44
    static let buttonHitHeight: CGFloat = 44
    static let outlineButtonHeight: CGFloat = 44
    static let columnMaxWidth: CGFloat = .infinity
    static let screenGutter: CGFloat = 16
    static let screenTop: CGFloat = 12
    static let screenBottom: CGFloat = 12
    /// The network's mark inside the round glass button at the leading edge of a feed's top bar:
    /// 8 in from the system's 44-point button on each side.
    static let toolbarMark: CGFloat = 28
    /// The system's tab bar as measured in Photos on iOS 27: 62 tall, 21 in from the screen's sides and
    /// bottom. Compose matches it at the bottom right, so the two share a height and a bottom edge.
    static let tabBarHeight: CGFloat = 62 // layout-ok: the system's tab bar, which the app doesn't set
    static let tabBarInset: CGFloat = 21 // layout-ok: the system's tab bar inset, which the app doesn't set
    static let composeGlyph = Font.system(size: 20, weight: .medium)
    /// The badge on an Activity row's avatar, and how far it hangs past the avatar's corner.
    static let badgeSize: CGFloat = 20
    static let badgeOverhang: CGFloat = 4
    static let badgeGlyph = Font.system(size: 10, weight: .bold)
    /// How small a toast starts as it fades in, and how long a confirmation such as Sent stays up.
    static let toastScale: CGFloat = 0.96
    static let toastSeconds = 2.5
    /// Link cards, pictures in posts, and the quoted post in Activity.
    static let cardRadius: CGFloat = 12
    // Network marks: a rounded square with the network's first letter. 12 at 40 points.
    static let markRadiusRatio: CGFloat = 0.3
    static let actionIconGap: CGFloat = 8
    /// A sheet's header, such as the composer's, and the bar along its bottom.
    static let sheetHeaderHeight: CGFloat = 56
    static let sheetBarHeight: CGFloat = 52
    /// Pictures in the composer are squares this size, and a link card beside one matches its height.
    static let attachmentSide: CGFloat = 140
    /// The × on an attachment: a circle this size in a 44-point target.
    static let removeButtonSize: CGFloat = 24
    /// Post pills are at least this wide, so Posting… doesn't move them.
    static let postPillWidth: CGFloat = 72
    /// Rows in Settings and lists like Members: a 44-point target with room above and below.
    static let listRowHeight: CGFloat = 56
    /// The picture on Your profile.
    static let profilePictureSize: CGFloat = 64
    /// Two or more pictures in a post: one row this tall, which swipes sideways from the text column
    /// off the screen's edge, as on X.
    static let pictureRowHeight: CGFloat = 256
    /// A picture in that row keeps its shape between these, width over height. Past them it's cropped.
    static let pictureRowTallest: CGFloat = 3 / 4
    static let pictureRowWidest: CGFloat = 1
    /// One picture fills the column, cropped when it's taller than this, width over height.
    static let singlePictureTallest: CGFloat = 4 / 5
    /// Activity, as on X: the people's pictures, overlapping a little, and your post's picture at the
    /// trailing edge.
    static let activityAvatarSize: CGFloat = 32
    static let activityAvatarOverlap: CGFloat = 4
    static let activityPictureSize: CGFloat = 64
    #endif

    // Grid: content runs from the gutter to the mirrored right gutter. Text in lists starts at textColumn.
    static let gutter: CGFloat = 16
    static let textColumn = gutter + avatarSize + avatarGap

    // Inside a post: name to text, and text to whatever is under it.
    static let castGap: CGFloat = 4
    // Reply and like. Each has a slot of its own width, so the heart stays put with a count or without.
    static let actionSlotWidth: CGFloat = 64
    static let actionSlotHeight: CGFloat = 20
    /// Below reply and like, so the icons end 11 above the divider like text does.
    static let actionsBottom: CGFloat = 8
    // Gaps in rows of controls and between a field and the controls under it.
    static let itemGap: CGFloat = 8
    static let groupGap: CGFloat = 12
    /// Above a label that starts another group on the same screen, such as Your networks.
    static let sectionGap: CGFloat = 24
    /// Bars at the bottom of a window, above and below their controls.
    static let barPadding: CGFloat = 12
    static let fieldInset: CGFloat = 14
    static let fieldRadius: CGFloat = 18
    static let markLetterRatio: CGFloat = 0.55
    /// The unread dot on a mark or the Activity button, with a paper ring so it reads on anything.
    static let unreadDot: CGFloat = 7
    static let unreadRing: CGFloat = 2

    // A symbol next to text takes that text's font. These are the exceptions: the glyphs that stand
    // alone as a control, and body-size marks in a fixed frame, which can't grow with Dynamic Type.
    static let markGlyph = Font.system(size: bodySize, weight: .semibold)

    private static func font(_ size: CGFloat, _ weight: Weight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        .custom("Inter-\(weight.rawValue)", size: size, relativeTo: textStyle)
    }

    #if os(macOS)
    private static func adaptive(light: UInt32, dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastAqua: rgb(contrastLight ?? light)
            case .accessibilityHighContrastDarkAqua: rgb(contrastDark ?? dark)
            case .darkAqua: rgb(dark)
            default: rgb(light)
            }
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    #else
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { rgb($0.userInterfaceStyle == .dark ? dark : light) })
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    #endif
}

/// A one-pixel rule. A 0.5-point line alternates between one and two pixels on 3x screens.
struct FatlineDivider: View {
    @Environment(\.displayScale) private var displayScale
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(FatlineStyle.line)
            .frame(height: 1 / displayScale)
            .padding(.horizontal, inset)
    }
}

extension View {
    func fatlineTitle(_ text: String) -> some View {
        #if os(macOS)
        // The Mac title bar draws the title itself, in the system font.
        navigationTitle(text)
            .toolbarBackground(FatlineStyle.paper, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
        // Small and centered in the system font, as in Messages, in the app's green. The system's title
        // can't take a color without changing the bar's appearance, so the bar's middle holds our own,
        // and `navigationTitle` stays for the back button and VoiceOver.
        navigationTitle(text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(verbatim: text)
                        .font(.headline)
                        .foregroundStyle(FatlineStyle.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        #endif
    }
}

extension View {
    /// For a step whose title is in the content, so the bar only holds the back button.
    func fatlineStepBar() -> some View {
        #if os(macOS)
        navigationTitle("")
            .toolbarBackground(FatlineStyle.paper, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
    }

    /// Keeps a step's main button in the same place from screen to screen.
    func fatlineBottomAction<Action: View>(
        gutter: CGFloat = FatlineStyle.screenGutter, bottom: CGFloat = FatlineStyle.screenBottom, @ViewBuilder _ action: () -> Action
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            action()
                .padding(.horizontal, gutter)
                .padding(.top, 12)
                .padding(.bottom, bottom)
                .frame(maxWidth: FatlineStyle.columnMaxWidth)
                .frame(maxWidth: .infinity)
                .background(FatlineStyle.paper)
        }
    }
}

extension Text {
    func fatlineScreenTitle() -> some View {
        font(FatlineStyle.screenTitle)
            .tracking(-0.4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The short title and single instruction at the top of every step after the splash.
struct FatlineStepHeader: View {
    let title: String
    let instruction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fatlineScreenTitle()
            Text(instruction)
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A secondary action beside a field. It has an outline because the field and a turned-off primary
/// button are already filled with `quiet`.
struct FatlineOutlineButton: ButtonStyle {
    @ScaledMetric(relativeTo: .footnote) private var height = FatlineStyle.outlineButtonHeight

    var fills = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FatlineStyle.metaStrong)
            .foregroundStyle(FatlineStyle.ink)
            .lineLimit(1)
            .padding(.horizontal, fills ? 8 : 14)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: height)
            .overlay { Capsule().strokeBorder(FatlineStyle.outline, lineWidth: 1) }
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct FatlinePrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight = FatlineStyle.compactButtonHeight
    @ScaledMetric(relativeTo: .subheadline) private var regularHeight = FatlineStyle.regularButtonHeight

    let compact: Bool
    let minWidth: CGFloat
    let isWorking: Bool

    init(compact: Bool = false, minWidth: CGFloat = 80, isWorking: Bool = false) {
        self.compact = compact
        self.minWidth = minWidth
        self.isWorking = isWorking
    }

    func makeBody(configuration: Configuration) -> some View {
        let filled = enabled || isWorking
        return configuration.label
            .font(FatlineStyle.bodyStrong)
            .foregroundStyle(filled ? FatlineStyle.actionInk : FatlineStyle.secondary)
            .padding(.horizontal, compact ? 16 : 23)
            .frame(minWidth: minWidth, minHeight: compact ? compactHeight : regularHeight)
            .background(filled ? FatlineStyle.action : FatlineStyle.quiet, in: .capsule)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .frame(minHeight: FatlineStyle.buttonHitHeight)
            .contentShape(.rect)
    }
}
