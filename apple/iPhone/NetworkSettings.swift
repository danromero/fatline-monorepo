import SwiftUI

/// Settings for the network that's showing, the last tab: you there with the network's name and
/// address, then Profile, Notifications, Members, and Manage Network for admins, Debug and the version, and Leave at
/// the bottom, apart so it's hard to reach by accident. A network that hasn't let you in has Debug and
/// Remove from This iPhone. It follows the Farcaster Settings row for row.
struct NetworkSettingsView: View {
    let membership: NetworkMembership
    let open: (NetworkSettingsRoute) -> Void

    @Environment(NetworkModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var waiting: Int?
    @State private var opening = false
    @State private var problem: String?
    @State private var confirmingLeave = false
    @State private var leaving = false

    private var approved: Bool { membership.status == .approved }
    private var handle: String { model.you?.handle ?? model.handle(for: membership.fid) }
    private var picture: URL? { model.you?.avatar.flatMap { FeedCast.networkMediaURL($0, host: membership.host) } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CastDivider()
                if approved {
                    IdentityRow(title: handle, meta: membership.host) {
                        CastAvatar(url: picture, handle: handle)
                    }
                    CastDivider()
                    Button { open(.profile) } label: { SettingsRow(symbol: "person", title: "Profile") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("network-settings-profile")
                    TextColumnDivider()
                    Button { open(.notifications) } label: {
                        SettingsRow(symbol: "bell", title: "Notifications", value: model.pushChoices(for: membership.host).level.title)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("network-settings-notifications")
                    TextColumnDivider()
                    Button { open(.members) } label: {
                        SettingsRow(symbol: "person.2", title: "Members", value: model.members.isEmpty ? nil : "\(model.members.count)")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("network-settings-members")
                    TextColumnDivider()
                    if membership.isAdmin {
                        Button(action: manage) {
                            SettingsRow(symbol: "slider.horizontal.3", title: "Manage Network", value: waiting.flatMap(Self.requests), trailing: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(opening)
                        .accessibilityHint("Opens the admin pages in Safari")
                        TextColumnDivider()
                    }
                }
                // Run Checks, the Launch Log, and the build. Debug builds' Forget Networks is in there too.
                DebugSettingsEntry { open(.debug) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Settings")
        .task {
            if membership.isAdmin && approved { waiting = try? await model.waitingRequests() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// Leave, or Remove from This iPhone for a network that never let you in.
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 0) {
            CastDivider()
            Button {
                if approved {
                    confirmingLeave = true
                } else {
                    model.forget(membership.host)
                }
            } label: {
                SettingsRow(
                    symbol: "rectangle.portrait.and.arrow.right",
                    title: approved ? (leaving ? "Leaving…" : "Leave \(membership.title)") : "Remove from This iPhone",
                    trailing: nil, color: FatlineStyle.danger
                )
            }
            .buttonStyle(.plain)
            .disabled(leaving)
            .accessibilityIdentifier("network-leave")
        }
        .background(FatlineStyle.paper)
        .confirmationDialog("Leave \(membership.title)?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive, action: leave)
        } message: {
            Text("Your posts, replies, and likes there are deleted. You can ask to join again.")
        }
    }

    /// Ends every session there and removes the network, so Farcaster shows, and this screen goes with it.
    private func leave() {
        leaving = true
        Task {
            do {
                try await model.leave()
                Platform.haptic(.done)
            } catch {
                Platform.haptic(.problem)
                problem = error.localizedDescription
            }
            leaving = false
        }
    }

    /// The one-time link to the admin pages, opened in Safari.
    private func manage() {
        opening = true
        Task {
            do { openURL(try await model.adminLink()) } catch { problem = error.localizedDescription }
            opening = false
        }
    }

    private static func requests(_ count: Int) -> String? {
        count == 0 ? nil : count == 1 ? "1 request" : "\(count) requests"
    }
}
