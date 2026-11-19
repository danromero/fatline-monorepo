import SwiftUI
import UIKit

/// Where the Farcaster feed's Settings has gone.
enum FarcasterSettingsRoute: Hashable {
    case people, connection, debug, checks, log
}

/// The Farcaster feed, with no tab bar since it has only Home, and Settings from the network menu.
struct FeedHome: View {
    let username: String?
    /// True right after signing in, which is when the follow list is read from the network.
    let signedIn: Bool
    /// Why Sign Out is unavailable right now, or nil when it's available.
    let signOutBlock: String?
    let notice: String?
    let latestPost: FeedCast?
    /// False when this iPhone's posting key is known to be one that can only post.
    let canDelete: Bool
    let connectionName: String
    let savedConnection: ConnectionChoice?
    let changeConnection: (ConnectionChoice) throws -> Void
    let compose: () -> Void
    let signOut: () throws -> Void
    let deleteCast: (FeedCast) async throws -> Void
    /// Starts joining a network, from the network menu. With no network yet, that's the way to add one.
    let addNetwork: () -> Void
    /// Shared with the composer's cover at the root, which zooms out of Compose.
    let composeZoom: Namespace.ID
    let othersHaveNews: Bool
    /// The Sent toast, which sits just above Compose.
    let toast: AnyView

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var model: FeedModel
    @State private var settingsPath: [FarcasterSettingsRoute] = []
    @State private var showingSettings = false
    @State private var confirmingDelete: FeedCast?
    @State private var deleting: Set<String> = []
    @State private var deleteError: String?
    @State private var showDeleteHelp = false

    private static let feedTop = "feed-top"
    /// Where a cast the feed scrolls to comes to rest: at the top, under the bar.
    private static let restAnchor = UnitPoint.top

    init(directory: URL, fid: UInt64, username: String?, signedIn: Bool, signOutBlock: String?, notice: String?, latestPost: FeedCast?,
         canDelete: Bool, connectionName: String, savedConnection: ConnectionChoice?,
         changeConnection: @escaping (ConnectionChoice) throws -> Void, compose: @escaping () -> Void,
         signOut: @escaping () throws -> Void, deleteCast: @escaping (FeedCast) async throws -> Void,
         addNetwork: @escaping () -> Void, composeZoom: Namespace.ID, othersHaveNews: Bool = false, toast: AnyView = AnyView(EmptyView())) {
        _model = State(initialValue: FeedModel(directory: directory, ownFID: fid, ownHandle: username))
        self.username = username
        self.signedIn = signedIn
        self.signOutBlock = signOutBlock
        self.notice = notice
        self.latestPost = latestPost
        self.canDelete = canDelete
        self.connectionName = connectionName
        self.savedConnection = savedConnection
        self.changeConnection = changeConnection
        self.compose = compose
        self.signOut = signOut
        self.deleteCast = deleteCast
        self.addNetwork = addNetwork
        self.composeZoom = composeZoom
        self.othersHaveNews = othersHaveNews
        self.toast = toast
    }

    private var picture: URL? { model.ownAvatarLink.flatMap(FeedCast.imageURL) }

    var body: some View {
        // One screen, so no tab bar. Compose sits where it does on a network, beside where the bar would be.
        home
            .tint(FatlineStyle.action)
            .overlay {
                ComposeButton(zoom: composeZoom, action: compose)
            }
        .sheet(isPresented: $showingSettings) { settings }
        .task { await model.start(signedIn: signedIn) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshIfStale() } } else { model.savePlace() }
        }
        .confirmationDialog(
            "Delete this cast?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { cast in
            Button("Delete", role: .destructive) { Task { await delete(cast) } }
        } message: { _ in
            Text("Farcaster apps will stop showing it. This can’t be undone.")
        }
        .alert("Couldn’t delete the cast", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Sign in again to delete", isPresented: $showDeleteHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(PostingError.postOnlyKey.errorDescription ?? "")
        }
    }

    /// Settings, from the network menu, as a sheet with its own navigation.
    private var settings: some View {
        NavigationStack(path: $settingsPath) {
            SettingsSheet {
                FarcasterSettings(
                    model: model, username: username, picture: picture, connectionName: connectionName,
                    signOutBlock: signOutBlock, signOut: signOut
                ) { settingsPath.append($0) }
            }
                .navigationDestination(for: FarcasterSettingsRoute.self) { route in
                    switch route {
                    case .people:
                        PeopleList(model: model)
                    case .connection:
                        ConnectionForm(settings: savedConnection) { choice in
                            try changeConnection(choice)
                            settingsPath = []
                        }
                    case .debug:
                        DebugView(scope: LaunchLog.farcaster) { next in
                            settingsPath.append(next == .checks ? .checks : .log)
                        }
                    case .checks:
                        ChecksView(.farcaster(model: model, keyNotice: notice))
                    case .log:
                        LaunchLogView(place: "Farcaster", scope: LaunchLog.farcaster)
                    }
                }
        }
    }

    /// The feed under the system's top bar: Home, small and centered, and Farcaster's mark at the top
    /// left opening the network menu, which is also the way to add a first network.
    private var home: some View {
        NavigationStack {
            feed
                // Room for Compose, as a tab bar would leave, so the last cast and the toast clear it.
                .safeAreaPadding(.bottom, FatlineStyle.tabBarHeight)
                .background(FatlineStyle.paper.ignoresSafeArea())
                .foregroundStyle(FatlineStyle.ink)
                .fatlineTitle("Home")
                .toolbar {
                    FeedBar(name: "Farcaster", label: menuLabel, addNetwork: addNetwork, openSettings: { showingSettings = true }) {
                        FarcasterMark(size: FatlineStyle.toolbarMark)
                            .unreadDot(othersHaveNews, inset: -3) // layout-ok: the dot sits over the mark's corner, as on a network's mark
                    }
                }
        }
    }

    private var feed: some View {
        let casts = model.casts
        let marker = model.marker(in: casts)
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    CastDivider()
                    if let notice {
                        FeedMessage(text: notice)
                        CastDivider()
                    }
                    if let status = model.status, !casts.isEmpty {
                        FeedMessage(text: status)
                        CastDivider()
                    }
                    ForEach(casts) { cast in
                        // One view per cast, so the feed can tell which cast is at the top of the screen.
                        VStack(spacing: 0) {
                            if cast.id == marker { FeedMarker() }
                            let handle = model.handle(for: cast.fid)
                            CastRow(cast: cast, handle: handle)
                                .opacity(deleting.contains(cast.hash) ? 0.4 : 1)
                                .contextMenu { menu(for: cast, handle: handle) }
                                .accessibilityIdentifier("feed-cast")
                            if cast.id != casts.last?.id { CastDivider() }
                        }
                    }
                }
                .scrollTargetLayout()
                .id(Self.feedTop)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { visible in
                let visible = Set(visible)
                if let top = casts.first(where: { visible.contains($0.id) }) { model.sawTop(top) }
            }
            .onChange(of: model.opening, initial: true) { _, cast in
                guard let cast else { return }
                // After this pass, so the saved casts are laid out before the scroll.
                Task {
                    // The marker is part of the cast's own view, so it shows at the top when it's there.
                    scroller.scrollTo(cast, anchor: Self.restAnchor)
                    model.opened()
                }
            }
            .onChange(of: casts.first?.id) { old, _ in
                // New casts go in above. Unless the reader was at the top, keep what they were reading in place.
                guard let reading = model.reading, reading != old else { return }
                scroller.scrollTo(reading, anchor: Self.restAnchor)
            }
            .onChange(of: latestPost) { _, post in
                guard let post else { return }
                model.addPosted(post)
                model.sawTop(post)
                scroller.scrollTo(Self.feedTop, anchor: .top)
                Task { await model.refresh(reason: "post") }
            }
        }
        // Stays under the title until the problem clears.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = model.problem, !casts.isEmpty {
                VStack(spacing: 0) {
                    FeedProblemBanner(problem: problem, lastChecked: model.lastChecked, checking: model.loading) {
                        Platform.haptic(.tap)
                        Task { await model.refresh(reason: "pull") }
                    }
                    FatlineDivider()
                }
                .background(FatlineStyle.paper)
            }
        }
        .overlay {
            if casts.isEmpty {
                Text(emptyMessage)
                    .font(FatlineStyle.body)
                    .foregroundStyle(FatlineStyle.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, FatlineStyle.gutter)
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await model.refresh(reason: "pull") }
        .overlay(alignment: .bottom) { toast.padding(.bottom, FatlineStyle.gutter) }
    }

    /// The long-press menu on a cast.
    @ViewBuilder private func menu(for cast: FeedCast, handle: String) -> some View {
        if !cast.text.isEmpty {
            Button("Copy Text", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = cast.text
                Platform.haptic(.tap)
            }
        }
        if let url = cast.farcasterURL(handle: handle) {
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.string = url.absoluteString
                Platform.haptic(.tap)
            }
            Button("Open in Farcaster", systemImage: "arrow.up.forward.app") { openURL(url) }
        }
        if model.isOwn(cast), !deleting.contains(cast.hash) {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                if canDelete { confirmingDelete = cast } else { showDeleteHelp = true }
            }
        }
    }

    private func delete(_ cast: FeedCast) async {
        deleting.insert(cast.hash)
        defer { deleting.remove(cast.hash) }
        do {
            try await deleteCast(cast)
            model.removeDeleted(cast)
        } catch PostingError.postOnlyKey {
            Platform.haptic(.problem)
            showDeleteHelp = true
        } catch {
            Platform.haptic(.problem)
            deleteError = error.localizedDescription
        }
    }

    private var emptyMessage: String {
        if let status = model.status { return status }
        if model.loading { return "Loading…" }
        if model.problem != nil { return "Couldn’t load the feed. Pull down to try again." }
        if model.hasLoadedFeed, model.people.isEmpty {
            return "You don’t follow anyone yet. Follow people in the Farcaster app, then refresh People."
        }
        if model.hasLoadedFeed, model.names.isEmpty { return "Everyone is hidden." }
        return "No recent casts."
    }

    private var menuLabel: String {
        "Farcaster. Networks and Settings" + (othersHaveNews ? ", news in another network" : "")
    }
}

/// Settings for Farcaster, from the network menu: you, People, Connection, then Debug and the version. Sign Out
/// sits apart at the bottom and asks first, so it's hard to reach by accident.
private struct FarcasterSettings: View {
    let model: FeedModel
    let username: String?
    let picture: URL?
    let connectionName: String
    let signOutBlock: String?
    let signOut: () throws -> Void
    let open: (FarcasterSettingsRoute) -> Void

    @State private var confirmingSignOut = false
    @State private var signOutError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CastDivider()
                if let username {
                    IdentityRow(title: username, meta: "Farcaster") {
                        CastAvatar(url: picture, handle: username)
                    }
                    CastDivider()
                }
                Button { open(.people) } label: { SettingsRow(symbol: "person.2", title: "People") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-people")
                TextColumnDivider()
                Button { open(.connection) } label: {
                    SettingsRow(symbol: "antenna.radiowaves.left.and.right", title: "Connection", value: connectionName)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-connection")
                TextColumnDivider()
                // Run Checks, the Launch Log, and the build. Copy Diagnostics' lines are in its report.
                DebugSettingsEntry { open(.debug) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { signOutSection }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Settings")
        .alert("Couldn’t sign out", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutError ?? "")
        }
    }

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CastDivider()
            Button { confirmingSignOut = true } label: {
                SettingsRow(symbol: "rectangle.portrait.and.arrow.right", title: "Sign Out", trailing: nil,
                            color: signOutBlock == nil ? FatlineStyle.danger : FatlineStyle.secondary)
            }
            .buttonStyle(.plain)
            .disabled(signOutBlock != nil)
            .accessibilityIdentifier("sign-out")
            .confirmationDialog("Sign out of Fatline?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    do { try signOut() } catch { signOutError = error.localizedDescription }
                }
            } message: {
                Text("This removes the posting key from this iPhone and keeps this account’s draft.")
            }
            if let signOutBlock {
                Text(signOutBlock)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FatlineStyle.textColumn)
                    .padding(.trailing, FatlineStyle.gutter)
                    .padding(.bottom, FatlineStyle.itemGap)
            }
        }
        .background(FatlineStyle.paper)
    }
}

private struct PeopleList: View {
    let model: FeedModel

    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if let message = error ?? (model.peopleRefreshFailed ? "Couldn’t refresh. Try again in a minute." : nil) {
                        FeedMessage(text: message)
                        CastDivider()
                    }
                    ForEach(model.people) { person in
                        row(person)
                        if person.id != model.people.last?.id { CastDivider() }
                    }
                    Text("To change who you follow, use the Farcaster app.")
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FatlineStyle.gutter)
                        .padding(.vertical, FatlineStyle.rowPadding)
                }
            }
        }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("People")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                refreshButton
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// Only this button rereads the list, because it costs credits and the feed doesn't need it to stay current.
    private var refreshButton: some View {
        Button {
            Platform.haptic(.tap)
            Task { await model.refreshPeople() }
        } label: {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .font(FatlineStyle.body)
                    .foregroundStyle(FatlineStyle.secondary)
                    .opacity(model.refreshingPeople ? 0 : 1)
                if model.refreshingPeople { ProgressView().controlSize(.small) }
            }
        }
        .disabled(model.refreshingPeople)
        .accessibilityLabel(model.refreshingPeople ? "Refreshing people you follow" : "Refresh people you follow")
        .accessibilityIdentifier("refresh-people")
    }

    private func row(_ person: FeedModel.Person) -> some View {
        let hidden = model.isHidden(person)
        let action = hidden ? "Unhide" : "Hide"
        return HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.groupGap) {
            Text(person.handle)
                .font(FatlineStyle.bodyStrong)
                .foregroundStyle(hidden ? FatlineStyle.secondary : FatlineStyle.ink)
            Spacer(minLength: 8)
            Button {
                do {
                    try model.toggleVisibility(person)
                    Platform.haptic(.pick)
                    error = nil
                } catch { self.error = "Couldn’t save the change." }
            } label: {
                Text(action)
                    .font(FatlineStyle.body)
                    .foregroundStyle(hidden ? FatlineStyle.ink : FatlineStyle.secondary)
                    .frame(minWidth: FatlineStyle.postPillWidth, minHeight: FatlineStyle.buttonHitHeight, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(action) \(person.handle)")
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .frame(minHeight: FatlineStyle.listRowHeight)
    }
}
