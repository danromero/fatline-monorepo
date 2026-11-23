import XCTest
@testable import Fatline

/// What a network is told was read for twice-a-day summaries: only what its feed showed, at most once a
/// minute, all at once on going to the background.
final class SeenReportsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    func testNothingShownTellsNothing() {
        var reports = SeenReports()
        XCTAssertNil(reports.due("pine.example", now: true, at: start))
        reports.show("pine.example", upTo: 0)
        XCTAssertNil(reports.due("pine.example", now: true, at: start), "An empty feed isn't a read")
    }

    func testAtMostOnceAMinute() {
        var reports = SeenReports()
        reports.show("pine.example", upTo: 100)
        XCTAssertEqual(reports.due("pine.example", at: start), 100)
        reports.show("pine.example", upTo: 200)
        XCTAssertNil(reports.due("pine.example", at: start.addingTimeInterval(30)), "Within the minute")
        XCTAssertEqual(reports.due("pine.example", at: start.addingTimeInterval(61)), 200)
        XCTAssertNil(reports.due("pine.example", at: start.addingTimeInterval(200)), "Nothing newer to tell")
    }

    func testNowSkipsTheWait() {
        var reports = SeenReports()
        reports.show("pine.example", upTo: 100)
        _ = reports.due("pine.example", at: start)
        reports.show("pine.example", upTo: 200)
        XCTAssertEqual(reports.due("pine.example", now: true, at: start.addingTimeInterval(5)), 200)
    }

    func testOnlyMovesForward() {
        var reports = SeenReports()
        reports.show("pine.example", upTo: 200)
        reports.show("pine.example", upTo: 100)
        XCTAssertEqual(reports.shown["pine.example"], 200, "A shorter read, such as after a delete, doesn't take it back")
    }

    func testGoingToTheBackgroundTellsEveryNetworkShown() {
        var reports = SeenReports()
        reports.show("pine.example", upTo: 100)
        reports.show("cabin.example", upTo: 50)
        _ = reports.due("pine.example", at: start)
        reports.show("pine.example", upTo: 150)
        let due = reports.allDue(at: start.addingTimeInterval(10))
        XCTAssertEqual(due.map(\.host), ["cabin.example", "pine.example"])
        XCTAssertEqual(due.map(\.time), [50, 150])
        XCTAssertTrue(reports.allDue(at: start.addingTimeInterval(20)).isEmpty, "Each told once")
    }
}
