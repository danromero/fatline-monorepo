import SwiftUI

@main
struct FatlineApp: App {
    @UIApplicationDelegateAdaptor(FatlineAppDelegate.self) private var appDelegate

    init() {
        // The unit tests' host skips it, or it would clear a Simulator's saved account.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let install = isTesting ? FreshInstall.Outcome.earlierInstall : FreshInstall.runForApp()
        LaunchLog.opened()
        if install == .cleared { LaunchLog.record(.info, "Fresh install", "Cleared the sign-in an earlier install left") }
    }

    var body: some Scene {
        WindowGroup { AppRoot() }
    }
}

/// The splash state belongs to a view, not the App: an animated change to App state doesn't reach
/// the window's views, so the splash would vanish without fading. It stays false for as long as
/// the window lives, so returning from the background never replays the splash.
private struct AppRoot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    @State private var splashGone = false

    var body: some View {
        Composer(splashGone: splashGone)
            .overlay {
                if showSplash {
                    SplashScreen()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.12)))
                }
            }
            .statusBarHidden(showSplash)
            .task {
                try? await Task.sleep(for: .seconds(0.4))
                withAnimation(.easeOut(duration: 0.3)) { showSplash = false } completion: { splashGone = true }
            }
            // For Debug's Launch Log: when the app left the screen and came back.
            .onChange(of: scenePhase) { old, phase in
                switch phase {
                case .background:
                    LaunchLog.record(.info, "Went to background")
                    LaunchLog.flush()
                case .inactive where old == .active:
                    LaunchLog.record(.info, "Went inactive")
                case .active:
                    LaunchLog.cameBack()
                    // Notifications may have been turned on or off in iOS Settings meanwhile.
                    Task { await PushCenter.shared.refreshAuthorization() }
                default:
                    break
                }
            }
    }
}

/// Matches the system launch screen in Info.plist exactly, so the handoff between them is invisible.
private struct SplashScreen: View {
    var body: some View {
        ZStack {
            Color("SplashBackground")
            Image("SplashMark")
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The focus state lives here because a full-screen cover is a separate presentation:
/// focus state owned by the view that presents the cover doesn't reach the editor.
private struct CastEditor: View {
    /// TextEditor's own space before the text and above its first line, which iOS sets.
    static let leadingInset: CGFloat = 5 // layout-ok: UITextView's line fragment padding
    static let topInset: CGFloat = 8 // layout-ok: UITextView's text container inset

    @Binding var text: String
    let ready: Bool
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(FatlineStyle.body)
            .lineSpacing(FatlineStyle.bodyLineSpacing)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .focused($focused)
            .accessibilityLabel("Cast draft")
            .disabled(!ready)
            .overlay(alignment: .topLeading) {
                if ready && text.isEmpty {
                    Text("Write a cast…")
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .padding(.leading, Self.leadingInset)
                        .padding(.top, Self.topInset)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            // The keyboard comes up with the cover, not after it.
            .defaultFocus($focused, true)
            .onAppear { focused = ready }
            .onChange(of: ready) { _, ready in focused = ready }
    }
}

/// Sent, or why a post wasn't confirmed. The session clears it after a few seconds. The toast fades
/// out in place rather than being taken away, so a screen that changes while it goes can't leave it behind.
private struct PostToastHost: View {
    let toast: PostToast?
    /// The last toast, which stays to fade out.
    @State private var last: PostToast?

    var body: some View {
        ZStack {
            if let shown = toast ?? last {
                FeedToastView(toast: shown)
                    .toastPresence(toast != nil)
                    .transition(Platform.reduceMotion ? .opacity : .toast)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.28), value: (toast ?? last)?.id)
        .onChange(of: toast?.id, initial: true) { _, _ in
            if let toast { last = toast }
        }
    }
}

private struct Composer: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var session = PostingSession()
    /// Private networks, beside Farcaster. Nothing shows them yet.
    @State private var networks = NetworkModel()
    /// Add Network was chosen in the network menu.
    @State private var addingNetwork = false
    @State private var showDiscardRetry = false
    @State private var builds = BuildCheck()
    /// The composer's cover zooms out of the Farcaster feed's Compose button.
    @Namespace private var composeZoom
    /// Your Farcaster picture, on the composer's gutter, as the feed last read it.
    @State private var ownPicture: URL?
    /// An alert shown during the splash would sit over it.
    let splashGone: Bool

    /// Changing the connection replaces the feed, so nothing keeps reading through the old one.
    private struct FeedIdentity: Hashable {
        let fid: UInt64
        let connection: Connection
    }

    private static let composerInset = FatlineStyle.gutter

    private func openLink(_ url: URL) {
        guard let target = networks.open(url) else { return }
        addingNetwork = target == .join
    }

    /// What the network reads restart on: another network, the app coming forward, or one joined or left.
    private struct NetworkPoll: Hashable {
        let host: String?
        let active: Bool
        let count: Int
    }

    var body: some View {
        Group {
            if let membership = networks.selected {
                // Its own identity, so switching networks starts clean.
                NetworkHome(membership: membership) { addingNetwork = true }
                    .id(membership.host)
            } else if let fid = session.account?.fid, session.savedConnection == nil, !Connection.isSetByLaunch {
                // After Start Over there's no account, so Welcome shows by itself.
                ConnectionSetup(signedInAs: session.account?.username ?? String(fid),
                                finish: session.useConnection, startOver: session.startOver)
            } else if let fid = session.account?.fid {
                FeedHome(
                    directory: PostingSession.accountFolder(fid),
                    fid: fid,
                    username: session.account?.username,
                    signedIn: session.signedInNow,
                    signOutBlock: session.signOutBlock,
                    notice: session.keyInactive ? PostingError.inactiveKey.errorDescription : nil,
                    latestPost: session.latestPost,
                    canDelete: session.keyCanDelete != false,
                    connectionName: session.connection.name,
                    savedConnection: session.savedConnection,
                    changeConnection: session.useConnection,
                    compose: { picture in
                        ownPicture = picture
                        session.openComposer()
                    },
                    signOut: session.signOut,
                    deleteCast: session.deleteCast,
                    addNetwork: { addingNetwork = true },
                    composeZoom: composeZoom,
                    othersHaveNews: networks.othersHaveNews,
                    // Sits above the tab bar.
                    toast: AnyView(Group { if !session.showComposer { postToastHost } })
                )
                .id(FeedIdentity(fid: fid, connection: session.connection))
            } else {
                GettingStarted(session: session) {
                    recoveryForm
                }
            }
        }
        .tint(FatlineStyle.action)
        // A network's feed counts as read only while the app is active with nothing over it.
        .onChange(of: scenePhase == .active && !addingNetwork, initial: true) { _, inFront in
            networks.appInFront = inFront
        }
        .fullScreenCover(isPresented: $addingNetwork) {
            AddNetworkFlow { addingNetwork = false }
        }
        // A post's link: `fatline://open` from its page, or its own address as a universal link.
        .onOpenURL(perform: openLink)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { openLink(url) }
        }
        // Reads the network showing, and looks for news in the others, now and each minute while the
        // app is in front. Coming forward starts it again, so it reads right away.
        .task(id: NetworkPoll(host: networks.selectedHost, active: scenePhase == .active, count: networks.memberships.count)) {
            guard scenePhase == .active, !networks.memberships.isEmpty else { return }
            while !Task.isCancelled {
                await networks.refresh()
                await networks.checkOthers()
                try? await Task.sleep(for: .seconds(NetworkModel.pollInterval))
            }
        }
        .fullScreenCover(isPresented: Bindable(session).showComposer) {
            composerSurface
                .tint(FatlineStyle.action)
                .navigationTransition(.zoom(sourceID: ComposeZoom.id, in: composeZoom))
        }
        .task(id: session.draft) {
            // A change to the draft cancels this wait, so a save happens once typing pauses.
            // Cancel, Sign Out, and leaving the app save right away.
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            if session.ready { session.saveDraft() }
        }
        .onAppear(perform: session.loadSavedAccount)
        .onAppear { PushCenter.shared.attach(networks) }
        // Someone already in a network when notifications came: iOS asks once, after the splash.
        .task(id: splashGone) {
            guard splashGone, networks.memberships.contains(where: { $0.status == .approved }) else { return }
            await PushCenter.shared.ask(for: nil)
        }
        // A tapped notification opens its network, over Add Network.
        .onChange(of: networks.notificationOpening) { _, opening in
            if opening != nil { addingNetwork = false }
        }
        .task(id: session.account?.fid) { await session.checkKey() }
        .task { await builds.runIfDue() }
        #if DEBUG
        .task { await networks.joinFromLaunch() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                if session.ready { session.saveDraft() }
                // What was read goes now, rather than waiting out the minute.
                networks.reportSeenNow()
                return
            }
            session.checkKeyIfDue()
            Task { await builds.runIfDue() }
        }
        // The composer is a full-screen cover, so the offer waits until it closes.
        .alert(builds.offered.map { "Fatline build \($0.build) is available" } ?? "", isPresented: Binding(
            get: { builds.offered != nil && splashGone && !session.showComposer },
            set: { if !$0 { builds.dismiss() } }
        ), presenting: builds.offered) { offer in
            Button("Open TestFlight") { openURL(offer.link) }
            Button("Later", role: .cancel) {}
        } message: { _ in
            Text("You have build \(builds.current).")
        }
        // Last, so the covers and sheets above have it too.
        .environment(networks)
    }

    /// The same header and column as a network's composer: your picture on the gutter and the cast in
    /// the feed's column.
    private var composerSurface: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CastDivider()
                HStack(alignment: .top, spacing: FatlineStyle.avatarGap) {
                    CastAvatar(url: ownPicture, handle: session.account?.username ?? "")
                        .padding(.top, FatlineStyle.avatarTopInset)
                        .accessibilityHidden(true)
                    CastEditor(text: Bindable(session).draft, ready: session.ready)
                        // The editor's own insets, 5 before the text and 8 above it, put its first letter
                        // on the column and its first line level with the picture, as in a feed row.
                        .padding(.leading, -CastEditor.leadingInset)
                        .padding(.top, -CastEditor.topInset)
                }
                .padding(.horizontal, Self.composerInset)
                .padding(.top, FatlineStyle.rowPadding)
            }
            .composerHeader(post: session.activePostTitle ?? (session.account?.pending == nil ? "Post" : "Retry"),
                            canPost: !session.sendDisabled, working: session.activePostTitle != nil, canCancel: !session.busy,
                            cancel: session.cancelComposer, send: {
                                Platform.haptic(.tap)
                                Task { await session.send() }
                            }) {
                ComposerTitle(name: "Farcaster", label: "Posting to Farcaster") {
                    FarcasterMark(size: ComposerTitle<EmptyView>.markSize)
                }
            }
            .background(FatlineStyle.paper.ignoresSafeArea())
        }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        // One tick on going over the limit, the moment Post turns off.
        .onChange(of: session.draft.utf8.count > 320) { _, over in
            if over { Platform.haptic(.pick) }
        }
        .confirmationDialog("Stop retrying this cast?", isPresented: $showDiscardRetry) {
            Button("Stop Retrying", role: .destructive, action: session.discardRetry)
        } message: {
            Text("Snapchain may already have received it. Your draft stays here.")
        }
        .overlay(alignment: .bottom) {
            // The feed takes over the toast as soon as the composer starts closing.
            if session.showComposer { postToastHost.padding(.bottom, FatlineStyle.groupGap) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Keeps the row's height when it is empty, so toasts always sit in the same place. From 280
            // bytes the count is on the trailing gutter, as a network composer's is in its bar.
            HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.itemGap) {
                composerStatus
                Spacer(minLength: FatlineStyle.itemGap)
                if session.draft.utf8.count >= 280 {
                    Text("\(session.draft.utf8.count) / 320")
                        .font(FatlineStyle.meta)
                        .monospacedDigit()
                        .foregroundStyle(session.draft.utf8.count > 320 ? FatlineStyle.danger : FatlineStyle.secondary)
                        .accessibilityLabel("\(session.draft.utf8.count) of 320 bytes")
                }
            }
            .font(FatlineStyle.body)
            .frame(maxWidth: .infinity, minHeight: FatlineStyle.buttonHitHeight, alignment: .leading)
            .padding(.horizontal, Self.composerInset)
        }
    }

    /// The feed and the composer each host this, because a full-screen cover hides whatever is behind it.
    private var postToastHost: some View {
        PostToastHost(toast: session.postToast)
            .padding(.horizontal, Self.composerInset)
    }

    private var recoveryForm: some View {
        RecoveryPhraseForm(
            busy: session.busy, error: session.recoveryError, hasPendingRegistration: session.account?.registration != nil,
            connect: importPhrase, retry: { Task { await session.completeRegistration() } }
        )
    }

    /// Signs in, and approves this iPhone for networks with the same phrase, so joining one later
    /// doesn't ask for it again. The phrase isn't kept. As the Mac's sign-in does.
    private func importPhrase(_ phrase: String) {
        session.importPhrase(phrase)
        let networks = networks
        if networks.needsPhrase { Task { try? await networks.approveDevice(phrase: phrase) } }
    }

    @ViewBuilder private var composerStatus: some View {
        if session.saveFailed {
            Button("Retry Save", action: session.saveDraft).frame(minHeight: FatlineStyle.buttonHitHeight)
        } else if !session.ready {
            Button("Retry Draft", action: session.loadDraft).frame(minHeight: FatlineStyle.buttonHitHeight)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.itemGap) {
                if let notice = session.notice {
                    Text(notice)
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                }
                if session.account?.pending != nil && !session.busy {
                    Button("Post Options") { showDiscardRetry = true }
                        .frame(minHeight: FatlineStyle.buttonHitHeight)
                }
            }
        }
    }
}
