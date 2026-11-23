import SwiftUI
import UIKit

// A Fatline network on iPhone: its feed and Activity as the system's tabs, with the network's mark at
// the top left opening the network menu, which switches networks and opens Settings. Farcaster's own
// feed shows when no network is selected.

/// Where a network's feed or Activity has gone from its first screen.
enum NetworkRoute: Hashable {
    /// A post and its replies. `lit` is a reply a notification was about, lit for a moment.
    case thread(NetworkPost, lit: String? = nil)
}

/// Where Settings has gone.
enum NetworkSettingsRoute: Hashable {
    case profile, notifications, members, debug, checks, log, pushTest
}

/// A network's screens, or where it stands while the admin decides.
struct NetworkHome: View {
    let membership: NetworkMembership
    /// Starts joining another network, from the network menu.
    let addNetwork: () -> Void

    @Environment(NetworkModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var tab = FatlineTab.home
    @State private var path: [NetworkRoute] = []
    @State private var activityPath: [NetworkRoute] = []
    @State private var settingsPath: [NetworkSettingsRoute] = []
    @State private var composing = false
    @State private var showingSettings = false
    @Namespace private var composeZoom

    private var approved: Bool { membership.status == .approved }
    /// The feed, or a post opened from it, is the screen in front, for twice-a-day summaries' "read".
    private var feedInFront: Bool { approved && tab == .home && !showingSettings && !composing }

    private func openLinkedPost() async {
        guard approved, let link = model.linkedPost(in: membership.host) else { return }
        do {
            let post = try await model.linkedThread(link.hash)
            showingSettings = false
            composing = false
            tab = .home
            path = [.thread(post)]
            model.linkedPostOpened(link)
        } catch is CancellationError {
            return
        } catch {
            model.linkedPostOpened(link)
            model.toast = "That post isn’t here."
        }
    }

    /// What a notification's screen waits on: the network letting you in, for "You're in."
    private struct NotificationKey: Hashable {
        let opening: NetworkModel.NotificationOpening?
        let approved: Bool
    }

    /// A tapped notification's screen: a post with a reply lit, the feed, Activity, or the admin pages.
    private func openNotification() async {
        guard let opening = model.notificationOpening(in: membership.host) else { return }
        // A waiting request shows where it stands until the network lets you in.
        guard approved else {
            if opening.target == .feed { model.notificationOpened(opening) }
            return
        }
        showingSettings = false
        composing = false
        switch opening.target {
        case .thread(let hash, let lit):
            do {
                let post = try await model.thread(hash).post
                tab = .home
                path = [.thread(post, lit: lit)]
            } catch is CancellationError {
                return
            } catch {
                model.toast = "That post isn’t here."
            }
        case .feed:
            tab = .home
            path = []
        case .activity:
            tab = .activity
            activityPath = []
        case .manage:
            tab = .home
            if membership.isAdmin, let link = try? await model.adminLink() { openURL(link) }
        }
        model.notificationOpened(opening)
    }

    var body: some View {
        // Each tab keeps its own navigation, so coming back finds it as it was.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: FatlineTab.home) {
                home
            }
            if approved {
                Tab("Activity", systemImage: "tray", value: FatlineTab.activity) {
                    activity
                }
                .badge(model.newActivityCount)
            }
        }
        // Two tabs make a small bar, so it stays full while you read, with Activity's count in view.
        .tabBarMinimizeBehavior(.never)
        // A sidebar on iPad, when the app gets there.
        .tabViewStyle(.sidebarAdaptable)
        .tint(FatlineStyle.action)
        // iOS 27 requires the selection to be a tab that shows, and Activity goes if the network stops letting you in.
        .onChange(of: approved) { _, approved in
            if !approved, tab == .activity { tab = .home }
        }
        // Beside the tab bar on both tabs' first screens. A post has its reply bar there instead.
        .overlay {
            ZStack {
                if approved, showsCompose {
                    ComposeButton(zoom: composeZoom) { composing = true }
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: showsCompose)
        }
        .sheet(isPresented: $showingSettings) { settings }
        .onChange(of: feedInFront, initial: true) { _, inFront in model.feedShows(membership.host, inFront) }
        .onDisappear { model.feedShows(membership.host, false) }
        // A post link opens its thread on Home, once this network has let you in.
        .task(id: approved ? model.linkedPost : nil) { await openLinkedPost() }
        // A tapped notification opens its screen here.
        .task(id: NotificationKey(opening: model.notificationOpening(in: membership.host), approved: approved)) { await openNotification() }
        // This view lasts as long as its network shows, so the composer posts to the one it opened on.
        .sheet(isPresented: $composing) {
            NetworkComposer(host: membership.host)
                .tint(FatlineStyle.action)
                .navigationTransition(.zoom(sourceID: ComposeZoom.id, in: composeZoom))
        }
    }

    private var home: some View {
        NavigationStack(path: $path) {
            Group {
                switch membership.status {
                case .approved:
                    feed
                case .pending:
                    NetworkStatusView(status: .pending, host: membership.host, button: "Check Again") {
                        Platform.haptic(.tap)
                        Task { await model.checkAgain(membership.host) }
                    }
                    // Request sent: iOS asks, once, so this request hears "You're in."
                    .task { await PushCenter.shared.ask(for: membership.host) }
                case .refused:
                    NetworkStatusView(status: .refused, host: membership.host, removed: membership.removed, button: "Remove from This iPhone") {
                        model.forget(membership.host)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FatlineStyle.paper.ignoresSafeArea())
            .foregroundStyle(FatlineStyle.ink)
            // Small and centered, as in Messages. The network is the mark beside it.
            .fatlineTitle("Home")
            .toolbar { bar }
            .navigationDestination(for: NetworkRoute.self) { route in
                switch route {
                case .thread(let post, let lit): NetworkThreadView(post: post, lit: lit).tabBar(showingPost: true)
                }
            }
        }
        .tabBar(showingPost: !path.isEmpty)
    }

    private var activity: some View {
        NavigationStack(path: $activityPath) {
            NetworkActivityView(membership: membership, showing: tab == .activity) { activityPath.append(.thread($0)) }
                .toolbar { bar }
                .navigationDestination(for: NetworkRoute.self) { route in
                    switch route {
                    case .thread(let post, let lit): NetworkThreadView(post: post, lit: lit).tabBar(showingPost: true)
                    }
                }
        }
        .tabBar(showingPost: !activityPath.isEmpty)
    }

    /// Settings, from the network menu, as a sheet with its own navigation.
    private var settings: some View {
        NavigationStack(path: $settingsPath) {
            SettingsSheet {
                NetworkSettingsView(membership: membership) { settingsPath.append($0) }
            }
            .navigationDestination(for: NetworkSettingsRoute.self) { route in
                switch route {
                case .profile: NetworkProfileView()
                case .notifications: NetworkNotificationsView(membership: membership)
                case .members: NetworkMembersView()
                case .debug:
                    DebugView(scope: membership.host, testsNotifications: true, forgetNetworks: { model.forgetEverything() }) { next in
                        switch next {
                        case .checks: settingsPath.append(.checks)
                        case .log: settingsPath.append(.log)
                        case .pushTest: settingsPath.append(.pushTest)
                        }
                    }
                case .checks: ChecksView(.network(host: membership.host, model: model))
                case .pushTest: PushTestView(host: membership.host, model: model)
                case .log: LaunchLogView(place: membership.title, scope: membership.host)
                }
            }
        }
        // Mute and Saved happen in here, so their toasts show here too.
        .overlay(alignment: .bottom) { NetworkToastHost().padding(.bottom, FatlineStyle.gutter) }
        .tint(FatlineStyle.action)
    }

    /// The mark at the top left of both tabs, opening the network menu.
    @ToolbarContentBuilder private var bar: some ToolbarContent {
        FeedBar(name: approved ? membership.title : membership.host, label: menuLabel,
                addNetwork: addNetwork, openSettings: { showingSettings = true }) {
            if approved {
                NetworkMark(name: membership.title, icon: membership.icon, size: FatlineStyle.toolbarMark, dot: model.othersHaveNews)
            } else {
                NetworkWaitingMark(size: FatlineStyle.toolbarMark)
                    .unreadDot(model.othersHaveNews, inset: -3) // layout-ok: the dot sits over the mark's corner, as on a network's mark
            }
        }
    }

    /// Compose shows on each tab's first screen, not on a post.
    private var showsCompose: Bool {
        switch tab {
        case .home: path.isEmpty
        case .activity: activityPath.isEmpty
        }
    }

    private var menuLabel: String {
        "\(approved ? membership.label : membership.host). Networks and Settings" + (model.othersHaveNews ? ", news in another network" : "")
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                CastDivider()
                ForEach(model.posts) { post in
                    NetworkPostRow(post: post) { path.append(.thread(post)) }
                    if post.id != model.posts.last?.id { CastDivider() }
                }
            }
        }
        // Stays under the title until the problem clears, as on the Farcaster feed.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = model.problem, !model.posts.isEmpty {
                VStack(spacing: 0) {
                    FeedProblemBanner(message: problem, lastRead: model.lastRead, checking: model.loading) {
                        Platform.haptic(.tap)
                        Task { await model.refresh() }
                    }
                    FatlineDivider()
                }
                .background(FatlineStyle.paper)
            }
        }
        .overlay {
            if model.posts.isEmpty {
                Text(emptyMessage)
                    .font(FatlineStyle.body)
                    .foregroundStyle(FatlineStyle.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FatlineStyle.gutter)
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await model.refresh() }
        .overlay(alignment: .bottom) { NetworkToastHost().padding(.bottom, FatlineStyle.gutter) }
    }

    private var emptyMessage: String {
        if model.problem != nil { return "Couldn’t load this network. Pull down to try again." }
        if model.lastRead == nil { return "Loading…" }
        return "No posts yet"
    }
}

/// The network's confirmations, such as Sent, in the Farcaster feed's toast. The model clears each
/// after a couple of seconds. The toast fades out in place rather than being taken away, so a screen that
/// changes while it goes can't leave it behind.
struct NetworkToastHost: View {
    @Environment(NetworkModel.self) private var model
    /// The last toast, which stays to fade out.
    @State private var last: String?

    var body: some View {
        let shown = model.toast
        ZStack {
            if let text = shown ?? last {
                FeedToastView(toast: PostToast(detail: nil, confirmation: text))
                    .padding(.horizontal, FatlineStyle.gutter)
                    .toastPresence(shown != nil)
                    .transition(Platform.reduceMotion ? .opacity : .toast)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.28), value: shown ?? last)
        .onChange(of: shown, initial: true) { _, new in
            if let new { last = new }
        }
    }
}

/// A post with Reply and Like under it, each in a fixed 64-point slot so the heart stays put. Holding
/// it opens the system menu in the Mac's order: Reply, Copy Text, Copy Link, then Mute and Report for
/// someone else's post, or Delete for your own.
struct NetworkPostRow: View {
    enum Place { case feed, root, reply }

    let post: NetworkPost
    var place = Place.feed
    /// The reply a notification was about, lit for a moment with the menu's background.
    var lit = false
    /// Opens the post's replies, from the feed.
    var open: (() -> Void)? = nil
    /// What Reply does in a thread: goes to the reply field. From the feed, Reply opens the replies.
    var reply: (() -> Void)? = nil
    /// After a like goes through, for a list that holds its own copy of the post.
    var liked: () async -> Void = {}

    @Environment(NetworkModel.self) private var model
    /// The like as tapped, shown until the network's answer replaces it.
    @State private var pending: (liked: Bool, likes: Int)?
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var reporting = false
    @State private var reportNote = ""
    @State private var problem: Problem?

    private struct Problem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var isLiked: Bool { pending?.liked ?? post.liked }
    private var likes: Int { pending?.likes ?? post.likes }
    private var handle: String { model.handle(for: post.fid) }
    private var isOwn: Bool { post.fid == model.ownFID }
    private var replyAction: (() -> Void)? { reply ?? open }
    /// In the feed a reply says whose post it answers. Under that post it needn't.
    private var replyingTo: String? {
        guard place == .feed, post.parent != nil, let fid = post.parentFid else { return nil }
        return model.handle(for: fid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CastRow(cast: model.cast(for: post), handle: model.handle(for: post.fid), bottomInset: 0, highlighted: lit, replyingTo: replyingTo)
            ForEach(model.linkCards(for: post)) { card in
                NetworkLinkCard(card: card)
                    .padding(.leading, FatlineStyle.textColumn)
                    .padding(.trailing, FatlineStyle.gutter)
                    .padding(.top, FatlineStyle.castGap)
            }
            actions
        }
        .background(lit ? FatlineStyle.quiet : FatlineStyle.paper)
        .opacity(deleting ? 0.4 : 1)
        .contentShape(.rect)
        .onTapGesture { open?() }
        .contextMenu { menu }
        .accessibilityActions {
            if let open { Button("Open Replies", action: open) }
            if let replyAction, reply != nil { Button("Reply", action: replyAction) }
            if !post.text.isEmpty { Button("Copy Text", action: copyText) }
            if isOwn {
                Button("Delete…") { confirmingDelete = true }
            } else {
                Button("Mute \(handle)", action: mute)
                Button("Report…", action: startReport)
            }
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text(post.replies > 0 ? "Its replies stay, under “This post was deleted.”" : "It’s removed for everyone in this network.")
        }
        .alert("Report this post?", isPresented: $reporting) {
            TextField("Note", text: $reportNote, prompt: Text("Optional note"))
            Button("Cancel", role: .cancel) {}
            Button("Report", action: report)
        } message: {
            Text("The admin of \(model.selected?.title ?? "this network") will see it.")
        }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }), presenting: problem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }

    @ViewBuilder private var menu: some View {
        if let replyAction {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: replyAction)
        }
        if !post.text.isEmpty {
            Button("Copy Text", systemImage: "doc.on.doc", action: copyText)
        }
        if let link = model.link(for: post) {
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.string = link.absoluteString
                Platform.haptic(.tap)
            }
        }
        Divider()
        if isOwn {
            if !deleting {
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        } else {
            Button("Mute \(handle)", systemImage: "speaker.slash", action: mute)
            Button("Report…", systemImage: "exclamationmark.bubble", action: startReport)
        }
    }

    private func copyText() {
        UIPasteboard.general.string = post.text
        Platform.haptic(.tap)
    }

    private func delete() {
        deleting = true
        Task {
            do {
                try await model.delete(post)
            } catch {
                Platform.haptic(.problem)
                problem = Problem(title: "Couldn’t delete the post", message: error.localizedDescription)
            }
            deleting = false
        }
    }

    private func mute() {
        Task {
            do {
                try await model.setMuted(post.fid, true)
            } catch {
                Platform.haptic(.problem)
                problem = Problem(title: "Couldn’t mute \(handle)", message: error.localizedDescription)
            }
        }
    }

    private func startReport() {
        reportNote = ""
        reporting = true
    }

    private func report() {
        let note = String(reportNote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NetworkMessages.maxCharacters))
        Task {
            do {
                try await model.report(post, note: note)
            } catch {
                Platform.haptic(.problem)
                problem = Problem(title: "Couldn’t report the post", message: error.localizedDescription)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if place != .reply {
                slot(symbol: "bubble.left", count: post.replies, color: FatlineStyle.secondary) { (reply ?? open)?() }
                    .accessibilityLabel("Reply")
                    .accessibilityValue(post.replies == 1 ? "1 reply" : "\(post.replies) replies")
            }
            slot(symbol: isLiked ? "heart.fill" : "heart", count: likes,
                 color: isLiked ? FatlineStyle.action : FatlineStyle.secondary, action: like)
                .accessibilityLabel(isLiked ? "Unlike" : "Like")
                .accessibilityValue(likes == 1 ? "1 like" : "\(likes) likes")
        }
        .font(FatlineStyle.meta)
        .foregroundStyle(FatlineStyle.secondary)
        // Each slot insets its icon by 12, so the icons start on the text column.
        .padding(.leading, FatlineStyle.textColumn - FatlineStyle.groupGap)
        .padding(.vertical, FatlineStyle.castGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A 44-point target that takes 36 points of the row, so the icons sit 14 from the text above and
    /// the rule below, like the row's own padding. Counts are hidden at zero. The slot grows past 64 by
    /// 44 only for the largest text sizes, where its icon and count don't fit.
    private func slot(symbol: String, count: Int, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: FatlineStyle.actionIconGap) {
                Image(systemName: symbol)
                    .font(FatlineStyle.body)
                    .foregroundStyle(color)
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
            .padding(.leading, FatlineStyle.groupGap)
            .frame(minWidth: FatlineStyle.actionSlotWidth, minHeight: FatlineStyle.buttonHitHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, -FatlineStyle.castGap)
    }

    private func like() {
        Platform.haptic(.pick)
        let now = !isLiked
        pending = (now, max(0, likes + (now ? 1 : -1)))
        Task {
            await model.toggleLike(post)
            await liked()
            pending = nil
        }
    }
}

/// A post and its replies, pushed from the feed, each with Like, and a bar at the bottom to reply. A
/// post deleted since it was opened shows a placeholder, and its replies stay under it with no bar.
struct NetworkThreadView: View {
    let post: NetworkPost
    /// A reply a notification was about, lit when it first shows, then fading to paper.
    var lit: String? = nil

    @Environment(NetworkModel.self) private var model
    /// The reply lit now, and whether it has been, so a later read doesn't light it again.
    @State private var litShown: String?
    @State private var litDone = false
    @State private var root: NetworkPost?
    @State private var replies: [NetworkPost] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var reply = ""
    @State private var sending = false
    @State private var sendFailure: String?
    /// The reply just sent, under the others from the moment Post is tapped until the network's copy
    /// replaces it.
    @State private var sent: NetworkPost?
    /// The network this thread is on, which a reply goes to whatever is showing later.
    @State private var host: String?
    @FocusState private var replyFocused: Bool
    /// The bottom took room while the thread was at its end, so it's going back there.
    @State private var keepingEnd = false

    /// The post whose replies these are. Opened from a reply in the feed, it's the post that reply
    /// answers, which shows once it's read.
    private var shown: NetworkPost? { root ?? (post.parent == nil ? post : nil) }
    private var listed: [NetworkPost] {
        guard let sent, !replies.contains(where: { $0.hash == sent.hash }) else { return replies }
        return replies + [sent]
    }
    private static let end = "end"

    private var canSend: Bool {
        !sending && host != nil && !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && NetworkMessages.characterCount(reply) <= NetworkMessages.maxCharacters
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let shown {
                            if shown.deleted {
                                NetworkDeletedRow()
                            } else {
                                NetworkPostRow(post: shown, place: .root, reply: { replyFocused = true }, liked: load)
                            }
                            FatlineDivider()
                        }
                        if let failure {
                            FeedMessage(text: failure, color: FatlineStyle.danger)
                        } else if loaded && listed.isEmpty {
                            FeedMessage(text: "No replies yet")
                        }
                        ForEach(listed) { item in
                            NetworkPostRow(post: item, place: .reply, lit: item.hash == litShown, reply: { replyFocused = true }, liked: load)
                                // Not liked or deleted until the network has it.
                                .allowsHitTesting(item.hash != sent?.hash)
                                .id(item.id)
                            if item.id != listed.last?.id { CastDivider() }
                        }
                        // The thread's end, for keeping it in view.
                        Color.clear.frame(height: 0).id(Self.end)
                    }
                }
                // The keyboard, a send error, or a longer reply takes room from the bottom. If the thread was at
                // its end, it goes back there, so the last reply isn't left under the bar; scrolled up to read, it
                // stays where it was. The keyboard shrinks the view a moment before it adds its inset, so this
                // keeps going to the end until the thread is there again.
                .onScrollGeometryChange(for: ThreadViewport.self, of: ThreadViewport.init) { old, new in
                    // Replies loading change the content, not the room, so they don't count.
                    if new.contentHeight != old.contentHeight {
                        keepingEnd = false
                    } else if new.height < old.height, old.atEnd {
                        keepingEnd = true
                    }
                    if new.height > old.height || new.atEnd { keepingEnd = false }
                    guard keepingEnd else { return }
                    withAnimation(Platform.reduceMotion ? nil : .default) { scroller.scrollTo(Self.end, anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await load() }
                .overlay(alignment: .bottom) {
                    NetworkToastHost().padding(.bottom, FatlineStyle.groupGap)
                }
                .onChange(of: listed.last?.id) { _, last in
                    guard let last, litShown == nil else { return }
                    withAnimation(Platform.reduceMotion ? nil : .default) { scroller.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: litShown) { _, lit in
                    guard let lit, let item = replies.first(where: { $0.hash == lit }) else { return }
                    scroller.scrollTo(item.id, anchor: .center)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let shown, !shown.deleted { replyBar }
        }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle(model.selected?.title ?? "")
        .task {
            if host == nil { host = model.selectedHost }
            await load()
            await light()
        }
        // Its notifications don't show while it's open.
        .onAppear { if let host = host ?? model.selectedHost { model.threadOnScreen = (host, post.parent ?? post.hash) } }
        .onDisappear { if model.threadOnScreen?.hash == post.parent ?? post.hash { model.threadOnScreen = nil } }
        // The feed reads each minute, and its posts changing means this thread may have too.
        .onChange(of: model.posts) { Task { await load() } }
    }

    /// A round field and a Post pill on the gutter, riding the keyboard. It stops growing where the pill
    /// would crowd out the field, as the composer's header does.
    private var replyBar: some View {
        NetworkReplyBar(text: $reply, focused: $replyFocused, canSend: canSend, failure: sendFailure, send: send)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// The field empties and the reply shows under the others at once, then goes. If it doesn't go, it
    /// comes off the list and its text goes back in the field.
    private func send() {
        guard canSend, let host, let shown else { return }
        let text = reply
        Platform.haptic(.done)
        sending = true
        sendFailure = nil
        reply = ""
        Task {
            do {
                try await model.post(to: host, text: text, parent: shown) { sent = $0 }
                sending = false
                await load()
            } catch {
                Platform.haptic(.problem)
                sent = nil
                sending = false
                sendFailure = error.localizedDescription
                if reply.isEmpty { reply = text }
            }
        }
    }

    /// The reply a notification was about: lit with the menu's background, then back to paper.
    private func light() async {
        guard let lit, !litDone, replies.contains(where: { $0.hash == lit }) else { return }
        litDone = true
        litShown = lit
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation(.easeOut(duration: 1)) { litShown = nil }
    }

    private func load() async {
        do {
            let thread = try await model.thread(post.parent ?? post.hash)
            root = thread.post
            replies = thread.replies
            if replies.contains(where: { $0.hash == sent?.hash }) { sent = nil }
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }
}

/// How much of a thread shows above the reply bar and keyboard, and whether that reaches its end.
private struct ThreadViewport: Equatable {
    let height: CGFloat
    let atEnd: Bool
    /// The room the reply bar and keyboard take, so a change to it alone is seen too.
    let inset: CGFloat
    let contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        // The container's size leaves out the insets (the title bar, the reply bar, the keyboard), and the
        // offset counts from under the title bar.
        height = geometry.containerSize.height
        inset = geometry.contentInsets.bottom
        contentHeight = geometry.contentSize.height
        let shownTo = geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
        // Within a small gap of the end counts, for rounding as the bar and keyboard move.
        atEnd = shownTo >= geometry.contentSize.height - FatlineStyle.itemGap
    }
}

/// The bar under a thread. The pill stays on the last line as the field grows.
private struct NetworkReplyBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let canSend: Bool
    let failure: String?
    let send: () -> Void

    /// The field grows with the text size as the Post pill beside it does, so the two stay one height.
    @ScaledMetric(relativeTo: .subheadline) private var fieldHeight = FatlineStyle.regularButtonHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FatlineDivider()
            if let failure {
                Text(failure)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FatlineStyle.gutter)
                    .padding(.top, FatlineStyle.itemGap)
            }
            HStack(alignment: .bottom, spacing: FatlineStyle.itemGap) {
                TextField("Reply", text: $text, prompt: Text("Write a reply…").foregroundStyle(FatlineStyle.secondary), axis: .vertical)
                    .font(FatlineStyle.body)
                    .lineLimit(1...5)
                    .focused(focused)
                    .accessibilityIdentifier("network-reply-text")
                    .padding(.horizontal, FatlineStyle.fieldInset)
                    .padding(.vertical, FatlineStyle.itemGap)
                    .frame(minHeight: fieldHeight)
                    .background(FatlineStyle.quiet, in: .rect(cornerRadius: fieldHeight / 2, style: .continuous))
                // It stays Post: the reply shows in the thread as it goes.
                Button("Post", action: send)
                    .buttonStyle(FatlinePrimaryButton(minWidth: FatlineStyle.postPillWidth))
                    .disabled(!canSend)
                    .accessibilityIdentifier("network-reply-post")
            }
            .padding(.horizontal, FatlineStyle.gutter)
            .padding(.vertical, FatlineStyle.barPadding)
        }
        .background(FatlineStyle.paper.ignoresSafeArea(edges: .bottom))
    }
}

/// Where a deleted post was: an empty dashed circle where the avatar goes, and one line.
private struct NetworkDeletedRow: View {
    var body: some View {
        HStack(spacing: FatlineStyle.avatarGap) {
            Circle()
                .strokeBorder(FatlineStyle.outline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            Text("This post was deleted")
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
    }
}

private extension View {
    /// A post has its reply bar where the tab bar was. The post hides the bar, so it's gone as the post
    /// slides in. The tab's stack shows it again as soon as Back empties the stack, so it comes in with the
    /// feed and Compose; left to the post alone, it came back a beat after the post had gone.
    func tabBar(showingPost: Bool) -> some View {
        toolbar(showingPost ? .hidden : .visible, for: .tabBar)
    }
}
