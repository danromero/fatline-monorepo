import XCTest
@testable import Fatline

/// Debug's report stays short enough to read in a message, and says what failed.
final class DebugReportTests: XCTestCase {
    private let header = DebugReport.Header(
        place: "37 Club", build: "Fatline 0.1.1 (16)", system: "iOS 27.1", fid: 3,
        time: Date(timeIntervalSince1970: 1_795_000_000), updatedFrom: "15", seconds: 4.8
    )
    private let groups = ["This iPhone", "Saved on this iPhone", "37 Club"]

    private func check(_ id: Int, _ group: Int, _ title: String, _ state: DebugCheckState, _ detail: String = "Fine") -> DebugCheck {
        DebugCheck(id: id, group: group, title: title, detail: detail, milliseconds: nil, state: state)
    }

    func testProblemsComeFirstWithTheirDetail() {
        let checks = [
            check(0, 0, "Connection", .passed),
            check(1, 2, "Feed", .passed),
            check(2, 2, "Pictures from the cache", .failed, "0 of 3 cached copies decode: empty (image/avif), 0 bytes"),
        ]
        let lines = DebugReport.text(header: header, groups: groups, checks: checks, log: []).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Fatline report · 37 Club")
        XCTAssertEqual(lines[1], "Fatline 0.1.1 (16) · iOS 27.1 · Farcaster ID 3")
        XCTAssertTrue(lines[2].hasSuffix(" · first launch after build 15"))
        XCTAssertEqual(lines[3], "1 problem · 3 checks · 4.8 s")
        XCTAssertEqual(lines[5], "✗ 37 Club: Pictures from the cache")
        XCTAssertEqual(lines[6], "  0 of 3 cached copies decode: empty (image/avif), 0 bytes")
    }

    func testEachGroupIsOneLine() {
        let checks = [
            check(0, 0, "Connection", .passed), check(1, 0, "Storage", .passed),
            check(2, 1, "Keychain", .passed),
            check(3, 2, "Feed", .failed, "HTTP 500"), check(4, 2, "Members", .skipped),
        ]
        let text = DebugReport.text(header: header, groups: groups, checks: checks, log: [])
        XCTAssertTrue(text.contains("\n✓ This iPhone 2 of 2\n"))
        XCTAssertTrue(text.contains("\n✓ Saved on this iPhone 1 of 1\n"))
        XCTAssertTrue(text.contains("\n✗ 37 Club 0 of 2\n"))
        XCTAssertFalse(text.contains("Connection"), "Passing checks stay on screen, out of the report")
        XCTAssertTrue(text.hasSuffix(DebugReport.leavesOut))
    }

    func testNoProblems() {
        let text = DebugReport.text(header: header, groups: groups, checks: [check(0, 0, "Connection", .passed)], log: [])
        XCTAssertTrue(text.contains("\nNo problems · 1 check · 4.8 s\n"))
        XCTAssertFalse(text.contains("✗"))
    }

    /// Two launches at most, each with its newest notable events, never a read that went through.
    func testLogKeepsTwoLaunchesAndOnlyWhatMatters() {
        let newest = Date(timeIntervalSince1970: 1_795_000_000)
        let previous = newest.addingTimeInterval(-3600)
        let oldest = newest.addingTimeInterval(-7200)
        func event(_ launch: Date, _ minute: Int, _ outcome: LaunchEvent.Outcome, _ title: String) -> LaunchEvent {
            LaunchEvent(launch: launch, time: launch.addingTimeInterval(Double(minute * 60)), outcome: outcome, title: title, detail: "", scope: nil)
        }
        // Newest first, as LaunchLog keeps them.
        let launches = [
            LaunchRecord(started: newest, events: (1...15).reversed().map { event(newest, $0, .failed, "Picture failed \($0)") }
                + [event(newest, 0, .info, "Opened")]),
            LaunchRecord(started: previous, events: [
                event(previous, 2, .done, "Read 37 Club"), event(previous, 1, .cancelled, "Read 37 Club"), event(previous, 0, .info, "Opened"),
            ]),
            LaunchRecord(started: oldest, events: [event(oldest, 0, .info, "Opened")]),
        ]
        let lines = LaunchLog.reportLines(launches)
        // A heading and the 10 newest for this launch, a blank line, then a heading and the 2 notable ones before it.
        XCTAssertEqual(lines.count, 1 + LaunchLog.reportLimit + 1 + 1 + 2)
        XCTAssertTrue(lines[0].hasPrefix("This launch, "))
        XCTAssertTrue(lines[1].hasSuffix("Picture failed 6"), "Oldest first, among the 10 newest")
        XCTAssertTrue(lines[10].hasSuffix("Picture failed 15"))
        XCTAssertTrue(lines[13].hasSuffix("Opened"))
        XCTAssertTrue(lines[14].hasSuffix("Read 37 Club"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("Previous launch, ") }.count, 1)
    }
}
