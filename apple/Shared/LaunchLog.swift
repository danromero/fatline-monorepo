import Foundation

/// One thing the app did, for Debug's Launch Log and the report. Hosts, counts, and reasons only:
/// never post text, links, tokens, or keys.
struct LaunchEvent: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// Something that happened, such as opening the app.
        case info
        case done, failed, cancelled, skipped
    }

    /// When the launch this happened in started, which groups events by launch.
    let launch: Date
    var time: Date
    let outcome: Outcome
    let title: String
    let detail: String
    /// A network's host, `LaunchLog.farcaster`, or nil for the app itself, which shows everywhere.
    let scope: String?
    /// How many times it happened in a row, so a run of the same failure is one row.
    var count = 1

    /// Worth a line in a report: everything but a read that went through.
    var isNotable: Bool { outcome != .done }

    /// The event as one line of a report, after its time.
    var line: String {
        let times = count > 1 ? " (\(count) times)" : ""
        return title + times + (detail.isEmpty ? "" : " · " + detail)
    }
}

/// One launch's events, newest first.
struct LaunchRecord: Identifiable, Sendable {
    let started: Date
    let events: [LaunchEvent]
    var id: Date { started }
}

/// What the app did over its last launches. It's kept in a small file, so the launch before a quit is
/// still there when someone opens Debug after reopening the app.
@MainActor
enum LaunchLog {
    /// The scope of Farcaster's own events, such as its pictures.
    nonisolated static let farcaster = "farcaster"
    static let limit = 200
    /// At most this many of a launch's notable events go in a report.
    nonisolated static let reportLimit = 10

    private static let lastBuildKey = "launchLogLastBuild" + DevProfile.suffix
    private static let started = Date.now
    private static var events: [LaunchEvent] = load()
    private static var saveTask: Task<Void, Never>?
    /// How each network's last read went, so a read every minute that goes through isn't kept each time.
    private static var lastRead: [String: LaunchEvent.Outcome] = [:]
    /// The build this launch updated from, when it's the first launch after an update.
    private(set) static var updatedFrom: String?

    private static var file: URL { Platform.appFolder.appending(path: "launch-log.json") }

    /// Called once as the app starts. Notes the build, and whether it's the first launch since an update.
    static func opened() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        if let last = UserDefaults.standard.string(forKey: lastBuildKey), last != build { updatedFrom = last }
        UserDefaults.standard.set(build, forKey: lastBuildKey)
        record(.info, "Opened", updatedFrom.map { "Build \(build), first launch after \($0)" } ?? "Build \(build)")
        flush()
    }

    static func record(_ outcome: LaunchEvent.Outcome, _ title: String, _ detail: String = "", scope: String? = nil) {
        if var last = events.last, last.launch == started, last.outcome == outcome, last.title == title,
           last.detail == detail, last.scope == scope {
            last.count += 1
            last.time = .now
            events[events.count - 1] = last
        } else {
            events.append(LaunchEvent(launch: started, time: .now, outcome: outcome, title: title, detail: detail, scope: scope))
            if events.count > limit { events.removeFirst(events.count - limit) }
        }
        scheduleSave()
    }

    /// The app came back to the screen, after going inactive or to the background this launch. The first
    /// time it shows isn't kept, since Opened says that.
    static func cameBack() {
        guard let last = events.last(where: { $0.launch == started && $0.scope == nil }),
              last.title == "Went inactive" || last.title == "Went to background" else { return }
        record(.info, "Came back")
    }

    /// A network read. One that goes through like the one before it isn't kept, since the app reads every minute.
    static func read(host: String, name: String, _ outcome: LaunchEvent.Outcome, _ detail: String) {
        if outcome == .done, lastRead[host] == .done { return }
        lastRead[host] = outcome
        record(outcome, "Read \(name)", detail, scope: host)
    }

    /// Newest first. Only `scope`'s events and the app's own.
    static func launches(scope: String) -> [LaunchRecord] {
        let kept = events.filter { $0.scope == nil || $0.scope == scope }
        let starts = Set(kept.map(\.launch)).sorted(by: >)
        return starts.map { start in LaunchRecord(started: start, events: kept.filter { $0.launch == start }.reversed()) }
    }

    /// The log's part of a report: the last two launches, each with its newest notable events, oldest first.
    static func reportLines(scope: String) -> [String] {
        reportLines(launches(scope: scope))
    }

    nonisolated static func reportLines(_ launches: [LaunchRecord]) -> [String] {
        var lines: [String] = []
        for (index, launch) in launches.prefix(2).enumerated() {
            if index > 0 { lines.append("") }
            let when = launch.started.formatted(date: .omitted, time: .shortened)
            lines.append((index == 0 ? "This launch, " : "Previous launch, ") + when)
            for event in launch.events.filter(\.isNotable).prefix(reportLimit).reversed() {
                lines.append(event.time.formatted(date: .omitted, time: .standard) + " " + event.line)
            }
        }
        return lines
    }

    /// Writes now, as the app leaves the screen, since it may not come back.
    static func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private static func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            saveTask = nil
            save()
        }
    }

    private static func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: file, options: .atomic)
        } catch {
            // The log is a help, not a record: a failed write loses a few events and nothing else.
        }
    }

    private static func load() -> [LaunchEvent] {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([LaunchEvent].self, from: data) else { return [] }
        return Array(saved.suffix(limit))
    }
}
