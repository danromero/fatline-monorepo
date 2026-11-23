import SwiftUI
import UIKit

/// What this iPhone hears from a network, from Settings, built like Debug: Twice a day (the default),
/// All posts, Replies and mentions, or Off, a footnote, then the admin's own switches. When iOS has
/// Fatline's notifications off, a row opens iOS Settings and the choices dim. From the Notifications page
/// of the Private Networks canvas, approved November 20, 2026, with Twice a day approved November 21.
struct NetworkNotificationsView: View {
    let membership: NetworkMembership

    @Environment(NetworkModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var saving = false
    @State private var problem: String?

    private var push: PushCenter { .shared }
    private var choices: PushChoices { model.pushChoices(for: membership.host) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CastDivider()
                if push.offInSettings {
                    Button(action: openSettings) {
                        SettingsRow(symbol: "gearshape", title: "Turn On in iOS Settings", trailing: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Settings")
                    .accessibilityIdentifier("notifications-turn-on")
                    CastDivider()
                    footnote("Notifications are off for Fatline in iOS Settings, so nothing below reaches this iPhone.")
                    VStack(spacing: 0) {
                        CastDivider()
                        levels
                        CastDivider()
                        if membership.isAdmin { admin }
                    }
                    .disabled(true)
                    .opacity(0.4)
                    .padding(.top, FatlineStyle.sectionGap)
                } else {
                    levels
                    CastDivider()
                    footnote("Twice a day sends the posts you haven’t read at 9 a.m. and 9 p.m. Replies and mentions come right away. Never likes, or anyone you muted.")
                    if membership.isAdmin { admin }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Notifications")
        .task {
            await push.refreshAuthorization()
            // Someone who joined before notifications, and hasn't been asked: iOS asks here.
            await push.ask(for: membership.host)
        }
        .alert("Couldn’t change notifications", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// Twice a day, All posts, Replies and mentions, Off, with a check on the choice.
    private var levels: some View {
        VStack(spacing: 0) {
            ForEach(Array(PushChoices.Level.allCases.enumerated()), id: \.element) { index, level in
                if index > 0 { TextColumnDivider() }
                Button { choose(level) } label: {
                    SettingsRow(symbol: Self.symbol(level), title: level.title,
                                trailing: choices.level == level ? "checkmark" : nil, trailingColor: FatlineStyle.ink)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choices.level == level ? .isSelected : [])
                .accessibilityIdentifier("notifications-\(level.rawValue)")
            }
        }
        .disabled(saving)
    }

    /// Join requests and Reports, which an admin hears whatever the level.
    private var admin: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Admin")
            CastDivider()
            toggle(symbol: "person.badge.plus", title: "Join requests", isOn: \.requests)
            TextColumnDivider()
            toggle(symbol: "flag", title: "Reports", isOn: \.reports)
            CastDivider()
        }
        .disabled(saving)
    }

    private func toggle(symbol: String, title: String, isOn: WritableKeyPath<PushChoices, Bool>) -> some View {
        HStack(spacing: FatlineStyle.avatarGap) {
            Image(systemName: symbol)
                .font(FatlineStyle.rowGlyph)
                .frame(width: FatlineStyle.avatarSize, height: FatlineStyle.avatarSize)
                .accessibilityHidden(true)
            Toggle(title, isOn: Binding(get: { choices[keyPath: isOn] }, set: { on in
                var changed = choices
                changed[keyPath: isOn] = on
                save(changed)
            }))
            .font(FatlineStyle.body)
            .tint(FatlineStyle.action)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .frame(minHeight: FatlineStyle.listRowHeight)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(FatlineStyle.meta)
            .foregroundStyle(FatlineStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, FatlineStyle.textColumn)
            .padding(.trailing, FatlineStyle.gutter)
            .padding(.top, FatlineStyle.itemGap)
    }

    private static func symbol(_ level: PushChoices.Level) -> String {
        switch level {
        case .digest: "clock"
        case .all: "bell"
        case .replies: "at"
        case .off: "bell.slash"
        }
    }

    private func choose(_ level: PushChoices.Level) {
        guard level != choices.level else { return }
        Platform.haptic(.pick)
        var changed = choices
        changed.level = level
        save(changed)
    }

    private func save(_ changed: PushChoices) {
        saving = true
        Task {
            do {
                try await model.setPushChoices(changed, for: membership.host)
            } catch {
                Platform.haptic(.problem)
                problem = error.localizedDescription
            }
            saving = false
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
    }
}
