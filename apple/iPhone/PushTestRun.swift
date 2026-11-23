import Foundation
import UserNotifications

/// Debug's Send Test Notification for one network: each step a notification takes to this iPhone, in
/// order, stopping at the first that fails. iOS's permission, the device token, this network knowing
/// where this iPhone hears from it, the network sending a test note through the relay to Apple, and
/// the note arriving while Debug is open. The one step that changes anything sends that note.
@MainActor
@Observable
final class PushTestRun {
    let place: String
    private(set) var checks: [DebugCheck]
    private(set) var running = false
    private(set) var finished = false

    private let host: String
    private let model: NetworkModel
    @ObservationIgnored private var task: Task<Void, Never>?

    /// How long the last step waits for the note.
    static let arrivalSeconds = 30

    init(host: String, model: NetworkModel) {
        let name = model.memberships.first { $0.host == host }?.title ?? host
        self.host = host
        self.model = model
        place = name
        checks = Self.titles(name).enumerated().map {
            DebugCheck(id: $0.offset, group: 0, title: $0.element, detail: "Waiting", state: .waiting)
        }
    }

    private static func titles(_ name: String) -> [String] {
        ["Allowed in iOS Settings", "Device token", "Known to \(name)", "Sent by \(name)", "Arrived on this \(Platform.deviceName)"]
    }

    var problem: DebugCheck? { checks.first { $0.state == .failed } }
    var done: Int { checks.filter { $0.state != .waiting && $0.state != .running }.count }

    func start() {
        guard !running else { return }
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
    }

    private func run() async {
        running = true
        finished = false
        checks = checks.map { DebugCheck(id: $0.id, group: 0, title: $0.title, detail: "Waiting", state: .waiting) }
        let passed = await steps()
        for index in checks.indices where checks[index].state == .waiting || checks[index].state == .running {
            checks[index].state = .skipped
            checks[index].detail = Task.isCancelled ? "Stopped" : "Not tried"
        }
        running = false
        finished = true
        if let problem {
            LaunchLog.record(.failed, "Test notification", "\(problem.title): \(problem.detail)", scope: host)
        } else if passed {
            LaunchLog.record(.done, "Test notification", checks.last?.detail ?? "", scope: host)
        }
    }

    /// True when every step passed.
    private func steps() async -> Bool {
        let center = PushCenter.shared

        // iOS's permission. Asking shows iOS's alert only if it was never answered.
        guard let started = begin(0) else { return false }
        await center.ask(for: nil)
        switch center.authorization {
        case .authorized, .ephemeral:
            finish(0, .pass("Allowed", started.elapsed))
        case .provisional:
            finish(0, .pass("Delivered quietly: to Notification Center, without a banner or sound", started.elapsed))
        case .denied:
            return finish(0, .fail("Off for Fatline. Turn them on in iOS Settings → Notifications → Fatline.", started.elapsed))
        default:
            return finish(0, .fail("iOS hasn’t asked yet. Open the app again to see its question.", started.elapsed))
        }

        // The device token iOS gives at each launch.
        guard let started = begin(1) else { return false }
        guard model.hasPushToken else {
            let why = center.registrationError.map { "iOS gave none: \($0)" } ?? "iOS hasn’t given one this launch. Try again in a moment."
            return finish(1, .fail(why, started.elapsed))
        }
        let service = PushRelay.Environment.current == .production ? "production" : "sandbox, for Debug builds"
        finish(1, .pass("From iOS this launch, for Apple’s \(service)", started.elapsed))

        // The network has this iPhone's handle and key, made again if the relay forgot them.
        guard let started = begin(2) else { return false }
        do {
            let level = try await model.ensurePush(host)
            finish(2, .pass("\(level.title), through \(PushRelay.standard.origin.host() ?? "the relay")", started.elapsed))
        } catch {
            return finish(2, .fail(error.localizedDescription, started.elapsed))
        }

        // The network seals a test note and sends it through the relay, which says what Apple said.
        guard let started = begin(3) else { return false }
        let sentAt = Date.now
        do {
            let answer = try await model.withClient(host) { try await $0.testPush() }
            guard answer.result == .sent else {
                // The network forgot a gone handle, so it gets a new one now, for the next try.
                if answer.result == .gone { _ = try? await model.ensurePush(host) }
                return finish(3, .fail(answer.detail, started.elapsed))
            }
            finish(3, .pass(answer.detail, started.elapsed))
        } catch {
            return finish(3, .fail(error.localizedDescription, started.elapsed))
        }

        // The note arrives. The app is open, so iOS hands it to PushCenter before it shows.
        guard begin(4) != nil else { return false }
        let deadline = sentAt.addingTimeInterval(TimeInterval(Self.arrivalSeconds))
        while Date.now < deadline {
            if let seen = center.lastTest, seen.at >= sentAt, seen.host == host || !seen.opened {
                let seconds = String(format: "%.1f", seen.at.timeIntervalSince(sentAt))
                guard seen.opened else {
                    return finish(4, .fail("After \(seconds) s, but as “\(PushDelivery.fallback.body)”: the notification extension couldn’t open it."))
                }
                return finish(4, .pass("After \(seconds) s, in \(place)’s words"))
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return finish(4, .fail("Nothing in \(Self.arrivalSeconds) seconds. Apple took it, so look at Focus, and iOS Settings → Notifications → Fatline."))
    }

    /// Marks step `index` running, or nil when the run was stopped.
    private func begin(_ index: Int) -> ContinuousClock.Instant? {
        guard !Task.isCancelled else { return nil }
        checks[index].state = .running
        checks[index].detail = "Checking…"
        return .now
    }

    /// Records what step `index` found. True when it passed.
    @discardableResult
    private func finish(_ index: Int, _ outcome: DebugOutcome) -> Bool {
        checks[index].state = outcome.state
        checks[index].detail = outcome.detail
        checks[index].milliseconds = outcome.milliseconds
        return outcome.state == .passed
    }
}

private extension ContinuousClock.Instant {
    /// Milliseconds since this instant, as checks show them.
    var elapsed: Int {
        let duration = ContinuousClock.now - self
        return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
