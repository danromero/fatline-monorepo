import SwiftUI
import UIKit

/// A post's pictures over black, as Photos shows them. It zooms out of the picture tapped in the feed,
/// and swiping down or pinching in puts it back. Pinch or double-tap to zoom in, swipe sideways for the
/// post's other pictures, and tap to hide the buttons.
struct PictureViewer: View {
    let urls: [URL]
    /// The picture showing, which the feed zooms back into on close.
    @Binding var index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var chromeHidden = false
    /// The sharpest copy of each picture so far, for Share.
    @State private var loaded: [Int: CGImage] = [:]
    /// Darkens the buttons' glass, which would otherwise turn light over a bright picture.
    static let glassTint = Color.black.opacity(0.4)
    /// Pages zoomed in past fitting the screen. Swiping down pans one of these, not close the viewer.
    @State private var zoomed: Set<Int> = []

    var body: some View {
        // No navigation stack: in one, the page view's pages sit off center, below the bar by half its
        // height, and they'd move each time the bar hides. So the buttons float over the pictures.
        TabView(selection: $index) {
            ForEach(urls.indices, id: \.self) { page in
                PicturePage(url: urls[page], label: label(page), onTap: toggleChrome) {
                    loaded[page] = $0
                } onZoom: { isZoomed in
                    if isZoomed { zoomed.insert(page) } else { zoomed.remove(page) }
                }
                .tag(page)
                .ignoresSafeArea()
            }
        }
        .tabViewStyle(.page(indexDisplayMode: chromeHidden ? .never : .automatic))
        // Keeps the next page from showing past the edge as a swipe down shrinks the viewer. Before
        // ignoring the safe area, or it would clip to it.
        .clipped()
        .ignoresSafeArea()
        .background(.black)
        .overlay(alignment: .top) {
            if !chromeHidden {
                HStack {
                    Button(role: .close) { dismiss() } label: {
                        Label("Close", systemImage: "xmark").glassCircleLabel()
                    }
                    .glassCircle()
                    .accessibilityIdentifier("picture-close")
                    Spacer()
                    share
                }
                .padding(.horizontal, FatlineStyle.gutter)
                .transition(.opacity)
            }
        }
        // Dark glass on the buttons over the black, whatever the app's appearance. Not a preferred
        // color scheme, which would turn the feed dark behind the viewer too.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(chromeHidden)
        .persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
        .accessibilityAction(.escape) { dismiss() }
        .interactiveDismissDisabled(zoomed.contains(index))
    }

    /// Shares the picture itself, so Save Image and Copy work, once a copy has loaded.
    @ViewBuilder private var share: some View {
        let label = Label("Share", systemImage: "square.and.arrow.up").glassCircleLabel()
        if let image = loaded[index] {
            let picture = Image(decorative: image, scale: 1)
            ShareLink(item: picture, preview: SharePreview("Picture", image: picture)) { label }
                .glassCircle()
        } else {
            Button {} label: { label }
                .glassCircle()
                .disabled(true)
        }
    }

    private func label(_ page: Int) -> String {
        urls.count > 1 ? "Picture \(page + 1) of \(urls.count)" : "Picture"
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
    }
}

private extension View {
    /// A round glass button as tall as a hit target, like a bar's. Its glass is tinted dark, so the
    /// white glyph stays legible over a bright picture as well as over the black.
    func glassCircle() -> some View {
        buttonStyle(.plain)
            .glassEffect(.regular.tint(PictureViewer.glassTint).interactive(), in: .circle)
    }

    func glassCircleLabel() -> some View {
        labelStyle(.iconOnly)
            .font(.title3.weight(.medium))
            .frame(width: FatlineStyle.buttonHitHeight, height: FatlineStyle.buttonHitHeight)
            .contentShape(.circle)
    }
}

/// One picture: the feed's copy at once, then a sharper one for zooming in.
private struct PicturePage: View {
    let url: URL
    let label: String
    let onTap: () -> Void
    let onLoad: (CGImage) -> Void
    let onZoom: (Bool) -> Void

    @State private var sharp: CGImage?
    @State private var failed = false

    var body: some View {
        let image = sharp
            ?? CastImages.cached(url, maxPixels: CastImages.viewerPicturePixels)
            ?? CastImages.cached(url, maxPixels: CastImages.feedPicturePixels)
        ZoomingPicture(image: image, onTap: onTap, onZoom: onZoom)
            .overlay {
                if image == nil {
                    if failed {
                        Text("Picture unavailable")
                            .font(FatlineStyle.body)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
            .task(id: url) {
                if let image { onLoad(image) }
                sharp = await CastImages.load(url, maxPixels: CastImages.viewerPicturePixels)
                if let sharp { onLoad(sharp) } else { failed = image == nil }
            }
    }
}

/// UIScrollView's zooming, for its feel: zooming toward the fingers, momentum, and the bounce at
/// each limit.
private struct ZoomingPicture: UIViewRepresentable {
    let image: CGImage?
    let onTap: () -> Void
    let onZoom: (Bool) -> Void

    func makeUIView(context: Context) -> PictureScrollView {
        PictureScrollView(frame: .zero)
    }

    func updateUIView(_ view: PictureScrollView, context: Context) {
        view.onTap = onTap
        view.onZoom = onZoom
        view.show(image)
    }
}

private final class PictureScrollView: UIScrollView, UIScrollViewDelegate {
    var onTap: () -> Void = {}
    /// Whether the picture is zoomed in past fitting the screen, each time that changes.
    var onZoom: (Bool) -> Void = { _ in }

    private let imageView = UIImageView()
    private var shown: CGImage?
    private var fittedFor: CGSize = .zero
    /// The zoom at which the picture fills the screen, cropping its sides or its top and bottom.
    private var fillScale: CGFloat = 1

    /// The most a picture zooms, unless filling the screen takes more.
    private static let maxZoom: CGFloat = 4
    /// What a double tap zooms to when the picture already about fills the screen.
    private static let doubleTapZoom: CGFloat = 2.5
    /// Filling the screen counts as a zoom for a double tap only past this.
    private static let fillCountsAsZoom: CGFloat = 1.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { return nil }

    /// A sharper copy of the same picture takes the old one's place without moving or unzooming it.
    func show(_ image: CGImage?) {
        guard image !== shown else { return }
        let sameShape = shown.map { Self.ratio($0) } == image.map { Self.ratio($0) }
        shown = image
        imageView.image = image.map { UIImage(cgImage: $0) }
        if !sameShape { fit() }
    }

    /// The page view scrolls too, and the system blurs whatever runs under the status bar in a scroll
    /// view. Photos doesn't blur its pictures, so neither scroll view does here.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        for case let scrollView as UIScrollView in sequence(first: superview, next: { $0?.superview }).compactMap({ $0 }) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedFor { fit() }
    }

    /// Fits the picture to the screen, unzoomed and centered.
    private func fit() {
        fittedFor = bounds.size
        setZoomScale(1, animated: false)
        guard let shown, bounds.width > 0, bounds.height > 0 else {
            imageView.frame = .zero
            contentSize = .zero
            return
        }
        let size = CGSize(width: shown.width, height: shown.height)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        fillScale = max(bounds.width / fitted.width, bounds.height / fitted.height)
        minimumZoomScale = 1
        maximumZoomScale = max(Self.maxZoom, fillScale)
        center()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        reportZoom()
    }

    /// Keeps a picture smaller than the screen in its middle.
    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        reportZoom()
    }

    private var reportedZoomed = false

    /// Outside SwiftUI's update, since fitting a new picture zooms out during one.
    private func reportZoom() {
        let isZoomed = zoomScale > minimumZoomScale
        guard isZoomed != reportedZoomed else { return }
        reportedZoomed = isZoomed
        DispatchQueue.main.async { [onZoom] in onZoom(isZoomed) }
    }

    @objc private func tapped() { onTap() }

    /// Zooms in toward the tap, to fill the screen or to `doubleTapZoom`, or back out.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard shown != nil else { return }
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = fillScale > Self.fillCountsAsZoom ? fillScale : Self.doubleTapZoom
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    private static func ratio(_ image: CGImage) -> CGFloat {
        CGFloat(image.width) / CGFloat(max(image.height, 1))
    }
}
