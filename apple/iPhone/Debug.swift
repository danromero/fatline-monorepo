import SwiftUI

// Debug, at the bottom of Settings: Run Checks and the Launch Log for the place Settings belongs to, a
// network or Farcaster, never both. One button copies a short report to paste into a message. From
// the Fatline Debug menu canvas, approved November 19, 2026.

/// Where Debug goes.
enum DebugRoute: Hashable {
    case checks, log, pushTest
}

/// The Debug row at the bottom of Settings, in a group of its own, with the build under it.
struct DebugSettingsEntry: View {
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CastDivider()
            Button(action: open) { SettingsRow(symbol: "ladybug", title: "Debug") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-debug")
            CastDivider()
            Text(verbatim: FeedModel.versionLine)
                .font(FatlineStyle.meta)
                .foregroundStyle(FatlineStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, FatlineStyle.textColumn)
                .padding(.trailing, FatlineStyle.gutter)
                .padding(.top, FatlineStyle.itemGap)
        }
        .padding(.top, FatlineStyle.sectionGap)
    }
}

/// Debug itself: Run Checks and the Launch Log.
struct DebugView: View {
    /// The Launch Log's scope: the network's host, or `LaunchLog.farcaster`.
    let scope: String
    /// A network's Debug offers Send Test Notification; Farcaster's has no notifications.
    var testsNotifications = false
    /// Debug builds only: forgets every network on this iPhone, for testing.
    var forgetNetworks: (() -> Void)? = nil
    let open: (DebugRoute) -> Void

    var body: some View {
        let launches = LaunchLog.launches(scope: scope).count
        ScrollView {
            VStack(spacing: 0) {
                CastDivider()
                Button { open(.checks) } label: { SettingsRow(symbol: "checklist", title: "Run Checks") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("debug-run-checks")
                TextColumnDivider()
                Button { open(.log) } label: {
                    SettingsRow(symbol: "clock", title: "Launch Log", value: launches == 1 ? "1 launch" : "\(launches) launches")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("debug-launch-log")
                if testsNotifications {
                    TextColumnDivider()
                    Button { open(.pushTest) } label: { SettingsRow(symbol: "bell.badge", title: "Send Test Notification") }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("debug-test-notification")
                }
                CastDivider()
                Text(testsNotifications
                     ? "Checks only read. A test notification goes to this iPhone alone. A report leaves out keys, tokens, post text, drafts, and your recovery phrase."
                     : "Checks only read. A report leaves out keys, tokens, post text, drafts, and your recovery phrase.")
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, FatlineStyle.textColumn)
                    .padding(.trailing, FatlineStyle.gutter)
                    .padding(.top, FatlineStyle.itemGap)
                #if DEBUG
                if let forgetNetworks {
                    VStack(spacing: 0) {
                        CastDivider()
                        Button(action: forgetNetworks) {
                            SettingsRow(symbol: "trash", title: "Forget Networks on This iPhone", trailing: nil)
                        }
                        .buttonStyle(.plain)
                        CastDivider()
                    }
                    .padding(.top, FatlineStyle.sectionGap)
                }
                #endif
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Debug")
    }
}

/// Runs the checks as soon as it opens: a row while they run, then problems first and every group
/// folded to one row, which opens on a tap. Copy Report sits at the bottom.
struct ChecksView: View {
    @State private var run: CheckRun
    /// Groups opened by a tap. The group being checked is open while the run is under way.
    @State private var opened: Set<Int> = []
    @State private var copied = false

    init(_ target: CheckRun.Target) {
        _run = State(initialValue: CheckRun(target))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                summary
                CastDivider()
                if !run.running && !run.problems.isEmpty {
                    SectionLabel(text: "Problems")
                    CastDivider()
                    rows(run.problems, named: true)
                    CastDivider()
                    SectionLabel(text: "All checks")
                    CastDivider()
                }
                ForEach(run.groups.indices, id: \.self) { group in
                    let checks = run.checks.filter { $0.group == group }
                    let open = opened.contains(group) || run.currentGroup == group
                    if group > 0 { TextColumnDivider() }
                    Button { toggle(group) } label: { CheckGroupRow(name: run.groups[group], checks: checks, open: open) }
                        .buttonStyle(.plain)
                        .accessibilityHint(open ? "Hides its checks" : "Shows its checks")
                    if open {
                        TextColumnDivider()
                        rows(checks, named: false)
                    }
                }
                CastDivider()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { copyBar }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Run Checks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if run.running {
                    Button("Stop") { run.stop() }
                        .accessibilityIdentifier("debug-stop")
                } else {
                    Button {
                        opened = []
                        run.start()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Run Again")
                    .accessibilityIdentifier("debug-run-again")
                }
            }
        }
        .task { run.start() }
        .onDisappear { run.stop() }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private var summary: some View {
        let finished = run.finishedAt != nil && !run.running
        let problems = run.problems.count
        let title = finished ? DebugReport.summary(problems: problems) : "Checking \(run.groups[run.currentGroup ?? 0])…"
        let detail = finished
            ? "\(DebugReport.count(run.checks.count)) in \(String(format: "%.1f", run.seconds)) s"
            : "\(run.done) of \(run.checks.count)"
        return HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.avatarGap) {
            CheckGlyph(kind: finished ? (problems == 0 ? .passed : .failed) : .running)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(FatlineStyle.bodyStrong)
                Text(detail).font(FatlineStyle.meta).foregroundStyle(FatlineStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rows(_ checks: [DebugCheck], named: Bool) -> some View {
        ForEach(Array(checks.enumerated()), id: \.element.id) { offset, check in
            if offset > 0 { TextColumnDivider() }
            CheckRow(check: check, title: named ? "\(run.groups[check.group]): \(check.title)" : check.title)
        }
    }

    /// Copy Report, with where to paste it under it. It waits for the run to finish.
    private var copyBar: some View {
        VStack(spacing: FatlineStyle.itemGap) {
            Button(action: copy) {
                Group {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Text("Copy Report")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(FatlinePrimaryButton())
            .disabled(run.running)
            .accessibilityIdentifier("copy-report")
            Text("Paste it into a message or TestFlight feedback.")
                .font(FatlineStyle.meta)
                .foregroundStyle(FatlineStyle.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.groupGap)
        .background(FatlineStyle.paper)
        .overlay(alignment: .top) { CastDivider() }
    }

    private func toggle(_ group: Int) {
        if opened.remove(group) == nil { opened.insert(group) }
    }

    private func copy() {
        Platform.copyToClipboard(run.report)
        Platform.haptic(.tap)
        Platform.announce("Report copied")
        copied = true
    }
}

/// Send Test Notification: sends as soon as it opens, then shows each step a notification takes, as
/// Run Checks shows its checks. The notification's own banner shows over it when it arrives.
struct PushTestView: View {
    @State private var run: PushTestRun

    init(host: String, model: NetworkModel) {
        _run = State(initialValue: PushTestRun(host: host, model: model))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                summary
                CastDivider()
                ForEach(Array(run.checks.enumerated()), id: \.element.id) { offset, check in
                    if offset > 0 { TextColumnDivider() }
                    CheckRow(check: check, title: check.title)
                }
                CastDivider()
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Test Notification")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if run.running {
                    Button("Stop") { run.stop() }
                        .accessibilityIdentifier("test-notification-stop")
                } else {
                    Button { run.start() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Send Again")
                        .accessibilityIdentifier("test-notification-again")
                }
            }
        }
        .task { run.start() }
        .onDisappear { run.stop() }
    }

    private var summary: some View {
        let finished = run.finished && !run.running
        let problem = run.problem
        let title = !finished ? "Sending a test notification…" : problem == nil ? "It arrived" : "It didn’t arrive"
        let detail = !finished ? "\(run.done) of \(run.checks.count)" : problem.map { "Stopped at \($0.title)" } ?? "Notifications from \(run.place) reach this iPhone"
        return HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.avatarGap) {
            CheckGlyph(kind: finished ? (problem == nil ? .passed : .failed) : .running)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(FatlineStyle.bodyStrong)
                Text(verbatim: detail).font(FatlineStyle.meta).foregroundStyle(FatlineStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .accessibilityElement(children: .combine)
    }
}

/// Every event kept for this place, newest launch first. Copy copies the report's log part.
struct LaunchLogView: View {
    let place: String
    let scope: String
    @State private var copied = false

    var body: some View {
        let launches = LaunchLog.launches(scope: scope)
        ScrollView {
            LazyVStack(spacing: 0) {
                if launches.isEmpty {
                    Text("Nothing yet")
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .padding(.top, FatlineStyle.sectionGap)
                }
                // One lazy child per launch. Events keyed by their place would share keys across
                // launches in one lazy stack, and rows with a repeated key draw blank.
                ForEach(Array(launches.enumerated()), id: \.element.id) { index, launch in
                    VStack(spacing: 0) {
                        SectionLabel(text: heading(index, launch))
                        CastDivider()
                        ForEach(Array(launch.events.enumerated()), id: \.offset) { offset, event in
                            if offset > 0 { TextColumnDivider() }
                            LaunchEventRow(event: event)
                        }
                        CastDivider()
                    }
                }
            }
        }
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper.ignoresSafeArea())
        .fatlineTitle("Launch Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: copy) { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityLabel(copied ? "Copied" : "Copy Log")
                    .accessibilityIdentifier("copy-log")
            }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private func heading(_ index: Int, _ launch: LaunchRecord) -> String {
        switch index {
        case 0: "This launch · " + launch.started.formatted(date: .omitted, time: .shortened)
        case 1: "Previous launch · " + launch.started.formatted(date: .omitted, time: .shortened)
        default: "Earlier · " + launch.started.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func copy() {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let lines = ["Fatline launch log · \(place)", "\(FeedModel.versionLine) · \(Platform.systemName) \(system.majorVersion).\(system.minorVersion)", ""]
            + LaunchLog.reportLines(scope: scope) + ["", DebugReport.leavesOut]
        Platform.copyToClipboard(lines.joined(separator: "\n"))
        Platform.haptic(.tap)
        Platform.announce("Log copied")
        copied = true
    }
}

/// A group of checks folded to one row: its mark, its name, and how many passed.
private struct CheckGroupRow: View {
    let name: String
    let checks: [DebugCheck]
    let open: Bool

    var body: some View {
        HStack(spacing: FatlineStyle.avatarGap) {
            CheckGlyph(kind: kind)
                .frame(height: FatlineStyle.avatarSize)
            Text(name)
                .font(FatlineStyle.body)
                .lineLimit(1)
            Spacer(minLength: FatlineStyle.itemGap)
            Text(value)
                .font(FatlineStyle.meta)
                .foregroundStyle(FatlineStyle.secondary)
                .lineLimit(1)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(FatlineStyle.metaStrong)
                .foregroundStyle(FatlineStyle.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .frame(minHeight: FatlineStyle.listRowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var kind: CheckGlyph.Kind {
        if checks.contains(where: { $0.state == .failed }) { return .failed }
        if checks.contains(where: { $0.state == .running }) { return .running }
        if checks.allSatisfy({ $0.state == .waiting }) { return .waiting }
        if checks.allSatisfy({ $0.state == .passed }) { return .passed }
        return .skipped
    }

    private var value: String {
        if checks.contains(where: { $0.state == .running }) { return "Checking…" }
        if checks.allSatisfy({ $0.state == .waiting }) { return "Waiting" }
        return "\(checks.filter { $0.state == .passed }.count) of \(checks.count)"
    }
}

/// One check: its mark, its name, and what it found, with how long it took on the right.
private struct CheckRow: View {
    let check: DebugCheck
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.avatarGap) {
            CheckGlyph(kind: CheckGlyph.Kind(check.state))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(FatlineStyle.body)
                    .foregroundStyle(check.state == .waiting ? FatlineStyle.secondary : FatlineStyle.ink)
                Text(verbatim: check.detail)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let milliseconds = check.milliseconds {
                Text("\(milliseconds) ms")
                    .font(FatlineStyle.meta)
                    .monospacedDigit()
                    .foregroundStyle(FatlineStyle.secondary)
            }
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .accessibilityElement(children: .combine)
    }
}

/// One event in the Launch Log, with its time on the right, as a post's time sits.
private struct LaunchEventRow: View {
    let event: LaunchEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FatlineStyle.avatarGap) {
            CheckGlyph(kind: CheckGlyph.Kind(event.outcome))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: event.title)
                    .font(FatlineStyle.body)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(event.time.formatted(date: .omitted, time: .standard))
                .font(FatlineStyle.meta)
                .monospacedDigit()
                .foregroundStyle(FatlineStyle.secondary)
        }
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, FatlineStyle.rowPadding)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let times = event.count > 1 ? "\(event.count) times" : ""
        return [times, event.detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The mark in the avatar's column: a check, a cross, a spinner, or an empty circle while waiting.
private struct CheckGlyph: View {
    enum Kind {
        case passed, failed, warning, waiting, running, skipped, event

        init(_ state: DebugCheckState) {
            switch state {
            case .passed: self = .passed
            case .failed: self = .failed
            case .waiting: self = .waiting
            case .running: self = .running
            case .skipped: self = .skipped
            }
        }

        init(_ outcome: LaunchEvent.Outcome) {
            switch outcome {
            case .info: self = .event
            case .done: self = .passed
            case .failed: self = .failed
            case .cancelled, .skipped: self = .warning
            }
        }
    }

    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .passed:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(FatlineStyle.ink)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(FatlineStyle.danger)
            case .warning:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(FatlineStyle.danger)
            case .waiting:
                Image(systemName: "circle")
                    .foregroundStyle(FatlineStyle.outline)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundStyle(FatlineStyle.secondary)
            case .event:
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(FatlineStyle.ink)
            }
        }
        .font(FatlineStyle.rowGlyph)
        .frame(width: FatlineStyle.avatarSize)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch kind {
        case .passed: "Passed"
        case .failed: "Failed"
        case .warning: "Warning"
        case .waiting: "Waiting"
        case .running: "Checking"
        case .skipped: "Skipped"
        case .event: ""
        }
    }
}
