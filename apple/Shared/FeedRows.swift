import ImageIO
import SwiftUI

/// A cast's age, which ticks while the feed stays open so a new post doesn't read Now for minutes.
/// On a Mac, resting the pointer on it shows the full date in its place.
private struct CastTime: View {
    let cast: FeedCast
    #if os(macOS)
    @State private var hovering = false
    #endif

    private var fullDate: String { cast.date.formatted(date: .abbreviated, time: .shortened) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(label(at: context.date))
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.secondary)
                .fixedSize()
                .accessibilityLabel(fullDate)
        }
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }

    private func label(at now: Date) -> String {
        #if os(macOS)
        if hovering { return fullDate }
        #endif
        return cast.shortAge(at: now)
    }
}

/// A cast's text, built from plain text so nothing in a cast is read as Markdown.
private struct CastBodyText: View {
    let text: String

    var body: some View {
        #if os(macOS)
        styled(Self.markedText(FeedCast.linkedText(text)))
            .modifier(CastLinkHotspots())
        #else
        styled(Text(FeedCast.linkedText(text)))
        #endif
    }

    private func styled(_ text: Text) -> some View {
        text
            .font(FatlineStyle.body)
            .lineSpacing(FatlineStyle.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    #if os(macOS)
    /// Rebuilds the text piece by piece so each link can be found again once the text is laid out.
    private static func markedText(_ linked: AttributedString) -> Text {
        var result = Text(verbatim: "")
        for run in linked.runs {
            var piece = Text(AttributedString(linked[run.range]))
            if let url = run.link { piece = piece.customAttribute(CastLinkAttribute(url: url)) }
            result = Text("\(result)\(piece)")
        }
        return result
    }
    #endif
}

#if os(macOS)
private struct CastLinkAttribute: TextAttribute {
    let url: URL
}

/// SwiftUI gives text links no pointing-hand cursor on a Mac, so an invisible area over each piece
/// of a link shows the hand and opens the link.
private struct CastLinkHotspots: ViewModifier {
    @Environment(\.openURL) private var openURL

    private struct Hotspot: Identifiable {
        let id: Int
        let url: URL
        let rect: CGRect
    }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                ForEach(hotspots(in: layouts, proxy: proxy)) { spot in
                    // A button, so the link can be reached from the keyboard and by VoiceOver.
                    Button { openURL(spot.url) } label: {
                        Color.clear.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(width: spot.rect.width, height: spot.rect.height)
                    .position(x: spot.rect.midX, y: spot.rect.midY)
                    .pointerStyle(.link)
                    .accessibilityLabel("Open \(FeedCast.label(for: spot.url))")
                }
            }
        }
    }

    private func hotspots(in layouts: Text.LayoutKey.Value, proxy: GeometryProxy) -> [Hotspot] {
        var found: [Hotspot] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line {
                    guard let attribute = run[CastLinkAttribute.self] else { continue }
                    let rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    found.append(Hotspot(id: found.count, url: attribute.url, rect: rect))
                }
            }
        }
        return found
    }
}
#endif

/// What a picture's load task waits on: its link, and for one that failed, the feed reads since.
struct PictureTry: Hashable {
    let url: URL?
    let round: Int
}

/// The author's picture, or their initials until it loads or when there isn't one.
struct CastAvatar: View {
    let url: URL?
    let handle: String
    var background = FatlineStyle.quiet
    var size = FatlineStyle.avatarSize
    @State private var loaded: CGImage?
    @State private var failed = false

    private static let maxPixels = 128

    var body: some View {
        let image = loaded ?? url.flatMap { CastImages.cached($0, maxPixels: Self.maxPixels) }
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Text(String(handle.filter(\.isLetter).prefix(2)).uppercased())
                    .font(FatlineStyle.metaStrong)
                    .foregroundStyle(FatlineStyle.secondary)
                    // The circle doesn't grow with Dynamic Type, so neither do its initials.
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
        .frame(width: size, height: size)
        .background(background)
        .clipShape(.circle)
        // One that failed tries again after the next feed read.
        .task(id: PictureTry(url: url, round: failed ? CastImages.retryRound : 0)) {
            guard let url, image == nil else { return }
            loaded = await CastImages.load(url, maxPixels: Self.maxPixels)
            failed = loaded == nil
        }
    }
}

/// A picture attached to a cast. Tapping it on iPhone opens the cast's pictures full screen.
/// Clicking it on a Mac opens the full image in the browser.
struct CastPicture: View {
    /// How a picture takes its place.
    enum Layout {
        /// The Mac's: the column's width at its own shape, up to 4:5, shown whole inside that.
        case whole
        /// iPhone, one picture in a post: the column's width at its own shape, cropped at 4:5.
        case column
        /// iPhone, one of several in a row that swipes: the row's height, 3:4 to 1:1, cropped past that.
        case row
        /// iPhone, your post's picture on an Activity row: a small square, and not a button, since the
        /// row opens the replies.
        case activity
    }

    let url: URL
    /// Width over height, when the post said, so the picture takes its shape before it loads.
    var ratio: CGFloat? = nil
    var layout = Layout.whole
    /// Opens the picture viewer, on iPhone.
    var open: () -> Void = {}
    @State private var loaded: CGImage?
    @State private var failed = false

    private static let placeholderRatio: CGFloat = 4 / 3
    /// The tallest a picture's box gets on a Mac. A taller picture is shown whole inside it.
    private static let tallestRatio: CGFloat = 4 / 5

    private var maxPixels: Int {
        layout == .activity ? CastImages.activityPicturePixels : CastImages.feedPicturePixels
    }

    var body: some View {
        let image = loaded ?? CastImages.cached(url, maxPixels: maxPixels)
        Group {
            if layout == .activity {
                box(image)
            } else {
                opener { box(image) }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .pointerStyle(.link)
                    #endif
                    .accessibilityLabel("Open image")
            }
        }
        // One that failed tries again after the next feed read.
        .task(id: PictureTry(url: url, round: failed ? CastImages.retryRound : 0)) {
            guard image == nil else { return }
            loaded = await CastImages.load(url, maxPixels: maxPixels)
            failed = loaded == nil
        }
    }

    @ViewBuilder private func box(_ image: CGImage?) -> some View {
        let shape = image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? ratio
        switch layout {
        case .whole, .column:
            if failed && image == nil {
                Text("Image unavailable")
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .underline()
            } else if layout == .whole {
                FatlineStyle.quiet
                    .aspectRatio(max(shape ?? Self.placeholderRatio, Self.tallestRatio), contentMode: .fit)
                    .overlay { picture(image, fill: false) }
                    .clipShape(.rect(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                    .contentShape(.rect)
            } else {
                #if os(iOS)
                FatlineStyle.quiet
                    .aspectRatio(max(shape ?? Self.placeholderRatio, FatlineStyle.singlePictureTallest), contentMode: .fit)
                    .overlay { picture(image, fill: true) }
                    .clipShape(.rect(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                    .contentShape(.rect)
                #endif
            }
        case .row:
            #if os(iOS)
            let height = FatlineStyle.pictureRowHeight
            let kept = min(max(shape ?? FatlineStyle.pictureRowTallest, FatlineStyle.pictureRowTallest), FatlineStyle.pictureRowWidest)
            FatlineStyle.quiet
                .frame(width: (height * kept).rounded(), height: height)
                .overlay {
                    if failed && image == nil {
                        Text("Image unavailable")
                            .font(FatlineStyle.meta)
                            .foregroundStyle(FatlineStyle.secondary)
                    } else {
                        picture(image, fill: true)
                    }
                }
                .clipShape(.rect(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                .contentShape(.rect)
            #else
            EmptyView()
            #endif
        case .activity:
            #if os(iOS)
            FatlineStyle.quiet
                .frame(width: FatlineStyle.activityPictureSize, height: FatlineStyle.activityPictureSize)
                .overlay { picture(image, fill: true) }
                .clipShape(.rect(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                .accessibilityHidden(true)
            #else
            EmptyView()
            #endif
        }
    }

    @ViewBuilder private func picture(_ image: CGImage?, fill: Bool) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: fill ? .fill : .fit)
        }
    }

    @ViewBuilder private func opener<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        #if os(iOS)
        Button(action: open, label: label)
        #else
        Link(destination: url, label: label)
        #endif
    }
}

#if os(iOS)
/// Two or more pictures in one row that swipes sideways, as on X: from the text column off the
/// screen's edge, under the avatar's column once swiped. Each picture stops on the text column, and
/// the last one at the gutter.
private struct CastPictureRow: View {
    let pictures: [FeedCast.Picture]
    /// The picture showing in the viewer. The row follows it, so closing the viewer zooms back into a
    /// picture that's on screen.
    let shown: Int
    let zoom: Namespace.ID
    let open: (Int) -> Void
    @State private var position = ScrollPosition(idType: Int.self)

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: FatlineStyle.itemGap) {
                ForEach(pictures.indices, id: \.self) { index in
                    CastPicture(url: pictures[index].url, ratio: pictures[index].ratio, layout: .row) { open(index) }
                        .matchedTransitionSource(id: index, in: zoom) {
                            $0.clipShape(RoundedRectangle(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                        }
                        .accessibilityLabel("Open image \(index + 1) of \(pictures.count)")
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition($position)
        .contentMargins(.leading, FatlineStyle.textColumn, for: .scrollContent)
        .contentMargins(.trailing, FatlineStyle.gutter, for: .scrollContent)
        .frame(height: FatlineStyle.pictureRowHeight)
        // Past the column the row sits in, to both edges of the screen.
        .padding(.leading, -FatlineStyle.textColumn)
        .padding(.trailing, -FatlineStyle.gutter)
        .onChange(of: shown) { _, index in position.scrollTo(id: index) }
    }
}
#endif

struct CastRow: View {
    let cast: FeedCast
    let handle: String
    /// What the author did, after their name, as in "@alice replied".
    var action: String? = nil
    /// Zero when something sits under the row's text, like reply and like.
    var bottomInset = FatlineStyle.rowPadding
    /// While the row's menu is open.
    var highlighted = false
    /// A symbol on the avatar's corner that says what kind of row this is, as in Activity on iPhone.
    var badge: String? = nil
    /// Whose post a reply in the feed answers, for the line under the name.
    var replyingTo: String? = nil
    /// In place of the name and what they did, as a like's several names in Activity.
    var title: Text? = nil
    /// One quiet line under the header, cut short at its end, as the post a like in Activity is on.
    var summary: String? = nil

    #if os(iOS)
    @State private var viewingPictures = false
    /// The picture showing in the viewer, which it zooms back into when it closes.
    @State private var picture = 0
    @Namespace private var pictureZoom
    #endif

    /// On a Mac the links inside a cast's text are separate controls, which combining would hide.
    private var hasTextLinks: Bool {
        #if os(macOS)
        FeedCast.linkedText(cast.text).runs.contains { $0.link != nil }
        #else
        false
        #endif
    }

    var body: some View {
        let links = cast.webLinks
        let pictures = cast.pictures
        let images = pictures.map(\.url)
        HStack(alignment: .top, spacing: FatlineStyle.avatarGap) {
            CastAvatar(url: cast.avatarURL, handle: handle, background: highlighted ? FatlineStyle.paper : FatlineStyle.quiet)
                .overlay(alignment: .bottomTrailing) {
                    if let badge { CastBadge(symbol: badge) }
                }
                .padding(.top, FatlineStyle.avatarTopInset)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FatlineStyle.castGap) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    (title ?? header)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CastTime(cast: cast)
                }
                if let replyingTo {
                    Text("Replying to \(Text(verbatim: replyingTo).font(FatlineStyle.metaStrong))")
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                }
                if let summary {
                    Text(verbatim: summary)
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !cast.text.isEmpty {
                    CastBodyText(text: cast.text)
                }
                #if os(iOS)
                // 8 under the text, and the row's own padding under the pictures.
                if pictures.count == 1, let only = pictures.first {
                    CastPicture(url: only.url, ratio: only.ratio, layout: .column) { openPicture(0) }
                        .matchedTransitionSource(id: 0, in: pictureZoom) {
                            $0.clipShape(RoundedRectangle(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                        }
                        .padding(.top, FatlineStyle.castGap)
                } else if pictures.count > 1 {
                    CastPictureRow(pictures: pictures, shown: picture, zoom: pictureZoom, open: openPicture)
                        .padding(.top, FatlineStyle.castGap)
                }
                #else
                ForEach(pictures.indices, id: \.self) { index in
                    CastPicture(url: pictures[index].url, ratio: pictures[index].ratio)
                        .padding(.vertical, FatlineStyle.castGap)
                }
                #endif
                ForEach(links, id: \.self) { url in
                    Link(destination: url) {
                        // Two lines always fit a host this short, and a longer one gets as many as it needs.
                        Text(verbatim: FeedCast.label(for: url))
                            .font(FatlineStyle.body)
                            .underline()
                            .lineLimit((url.host()?.count ?? 0) > 30 ? nil : 2)
                            .truncationMode(.tail)
                    }
                    .tint(FatlineStyle.action)
                    .foregroundStyle(FatlineStyle.action)
                    #if os(macOS)
                    .pointerStyle(.link)
                    #endif
                }
                if let quote = cast.quote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: quote.handle)
                            .font(FatlineStyle.metaStrong)
                        Text(verbatim: quote.text)
                            .font(FatlineStyle.meta)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(FatlineStyle.secondary)
                    // A quiet card, as a link's card is.
                    .padding(FatlineStyle.groupGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlighted ? FatlineStyle.paper : FatlineStyle.quiet,
                                in: .rect(cornerRadius: FatlineStyle.cardRadius, style: .continuous))
                    .padding(.top, FatlineStyle.castGap)
                }
            }
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.top, FatlineStyle.rowPadding)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The long-press preview lifts the row off the feed, so it carries the feed's paper with it.
        .background(highlighted ? FatlineStyle.quiet : FatlineStyle.paper)
        .contentShape(.rect)
        .accessibilityElement(children: links.isEmpty && images.isEmpty && !hasTextLinks ? .combine : .contain)
        #if os(iOS)
        .fullScreenCover(isPresented: $viewingPictures) {
            PictureViewer(urls: images, index: $picture)
                .navigationTransition(.zoom(sourceID: picture, in: pictureZoom))
        }
        #endif
    }

    /// Opens the post's pictures full screen, at the one tapped. A Mac opens the browser instead.
    private func openPicture(_ index: Int) {
        #if os(iOS)
        picture = index
        viewingPictures = true
        #endif
    }

    /// The name, bold, and what they did, in regular weight. One text, so a long line wraps as a sentence.
    private var header: Text {
        let name = Text(verbatim: handle).font(FatlineStyle.bodyStrong)
        guard let action else { return name }
        return Text("\(name) \(Text(action).font(FatlineStyle.body))")
    }
}

/// What an Activity row is, on its avatar's corner: a filled circle with a paper ring, hanging just
/// past the avatar.
private struct CastBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(FatlineStyle.badgeGlyph)
            .foregroundStyle(FatlineStyle.actionInk)
            .frame(width: FatlineStyle.badgeSize, height: FatlineStyle.badgeSize)
            .background(FatlineStyle.action, in: .circle)
            .padding(FatlineStyle.unreadRing)
            .background(FatlineStyle.paper, in: .circle)
            .offset(x: FatlineStyle.badgeOverhang + FatlineStyle.unreadRing, y: FatlineStyle.badgeOverhang + FatlineStyle.unreadRing)
    }
}

/// A label over a group of rows, such as New in Activity.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FatlineStyle.metaStrong)
            .foregroundStyle(FatlineStyle.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FatlineStyle.gutter)
            .padding(.top, FatlineStyle.gutter)
            .padding(.bottom, FatlineStyle.castGap)
            .accessibilityAddTraits(.isHeader)
    }
}

#if os(macOS)
/// The Mac's round plus: lit from above, with one soft shadow under it. iPhone's Compose is the
/// system's prominent glass button in the top bar.
struct PlusFace: View {
    var body: some View {
        Image(systemName: "plus")
            .font(FatlineStyle.plusGlyph)
            .foregroundStyle(FatlineStyle.actionInk)
            .frame(width: FatlineStyle.plusSize, height: FatlineStyle.plusSize)
            .background(LinearGradient(colors: [FatlineStyle.actionLit, FatlineStyle.action], startPoint: .top, endPoint: .bottom), in: .circle)
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: FatlineStyle.floatShadow, radius: 12, y: 8) // layout-ok: the plus's shadow, as on the canvas
    }
}
#endif

/// Stays above the feed until the problem clears, because a feed that's quietly old looks like a quiet
/// day. Clicking or tapping it asks again. It uses the same columns as a cast row, with the mark where an avatar goes.
struct FeedProblemBanner: View {
    private let title: String
    private let detail: (Date) -> String
    let checking: Bool
    let retry: () -> Void

    init(problem: FeedModel.Problem, lastChecked: Date?, checking: Bool, retry: @escaping () -> Void) {
        title = Self.title(problem)
        detail = { Self.detail(problem, lastChecked: lastChecked, now: $0) }
        self.checking = checking
        self.retry = retry
    }

    /// A network's problem: what went wrong, and how old the posts showing are.
    init(message: String, lastRead: Date?, checking: Bool, retry: @escaping () -> Void) {
        title = message
        detail = { now in (lastRead.map { "Showing posts from \(Self.age(now.timeIntervalSince($0))) ago. " } ?? "") + "\(Platform.pressVerb) to try again." }
        self.checking = checking
        self.retry = retry
    }

    var body: some View {
        Button(action: retry) {
            HStack(alignment: .top, spacing: FatlineStyle.avatarGap) {
                Image(systemName: "exclamationmark")
                    .font(FatlineStyle.markGlyph)
                    .foregroundStyle(FatlineStyle.actionInk)
                    .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                    .background(FatlineStyle.action, in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FatlineStyle.bodyStrong)
                        .foregroundStyle(FatlineStyle.ink)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(checking ? "Checking…" : detail(context.date))
                            .font(FatlineStyle.meta)
                            .foregroundStyle(FatlineStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, FatlineStyle.gutter)
            .padding(.vertical, FatlineStyle.rowPadding)
            .background(FatlineStyle.quiet)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(checking)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Checks for new posts")
        .accessibilityIdentifier("feed-problem")
    }

    private static func title(_ problem: FeedModel.Problem) -> String {
        switch problem {
        case .paused, .limitReached: "Feed paused"
        case .unreachable: "Can’t reach the server"
        case .refused: "Feed stopped"
        }
    }

    private static func detail(_ problem: FeedModel.Problem, lastChecked: Date?, now: Date) -> String {
        let age = lastChecked.map { Self.age(now.timeIntervalSince($0)) }
        switch problem {
        case .paused:
            return (age.map { "Last updated \($0) ago. " } ?? "") + "New posts will appear when it’s back. \(Platform.pressVerb) to check."
        case .unreachable:
            return (age.map { "Showing posts from \($0) ago. " } ?? "") + "\(Platform.pressVerb) to try again."
        case .limitReached:
            return (age.map { "Showing posts from \($0) ago. " } ?? "") + "Limit reached. Try again later."
        case .refused:
            let next = Connection.isSetByLaunch ? "\(Platform.pressVerb) to try again." : "Check Connection in Settings."
            return (age.map { "Showing posts from \($0) ago. " } ?? "") + "The server turned down the request. \(next)"
        }
    }

    static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 1440 { return "\(minutes / 60) hr" }
        let days = minutes / 1440
        return days == 1 ? "1 day" : "\(days) days"
    }
}

struct CastDivider: View {
    var body: some View {
        FatlineDivider(inset: FatlineStyle.gutter)
    }
}

/// Sits above the newest cast seen on the last visit, when there are newer ones above it.
struct FeedMarker: View {
    var body: some View {
        Text("Left off here")
            .font(FatlineStyle.metaStrong)
            .foregroundStyle(FatlineStyle.action)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FatlineStyle.textColumn)
            .padding(.trailing, FatlineStyle.gutter)
            .padding(.vertical, 8)
            .accessibilityIdentifier("feed-marker")
        CastDivider()
    }
}

/// A status line inside a list. It starts on the same column as cast text.
struct FeedMessage: View {
    let text: String
    var color = FatlineStyle.secondary

    var body: some View {
        Text(text)
            .font(FatlineStyle.meta)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FatlineStyle.textColumn)
            .padding(.trailing, FatlineStyle.gutter)
            .padding(.vertical, FatlineStyle.rowPadding)
    }
}

/// A brief confirmation, or why a post couldn't be confirmed.
struct PostToast {
    let id = UUID()
    let detail: String?
    var confirmation = "Sent"
    var title: String { detail == nil ? confirmation : "Post not confirmed" }
}

struct FeedToastView: View {
    let toast: PostToast

    var body: some View {
        HStack(alignment: .top, spacing: FatlineStyle.textColumn - FatlineStyle.gutter - 12 - 20) {
            Image(systemName: toast.detail == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(FatlineStyle.markGlyph)
                .frame(width: 20, height: 20)
                .foregroundStyle(toast.detail == nil ? FatlineStyle.action : FatlineStyle.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(toast.title)
                    .font(FatlineStyle.bodyStrong)
                    .frame(minHeight: 20, alignment: .leading)
                if let detail = toast.detail {
                    Text(detail)
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FatlineStyle.quiet, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(FatlineStyle.line)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post-toast")
    }
}
