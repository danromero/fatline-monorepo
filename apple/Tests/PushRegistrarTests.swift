import XCTest
@testable import Fatline

/// Each joined network gets its own handle and is told it; forgotten handles are made again; leaving
/// cleans up. Against a stand-in relay, network, and store.
@MainActor
final class PushRegistrarTests: XCTestCase {
    /// A relay that hands out numbered handles and forgets the ones it's told to.
    private final class Relay: @unchecked Sendable {
        var known: Set<String> = []
        var made = 0
        var log: [String] = []
        var down = false

        var transport: NetworkClient.Transport {
            { request in
                let path = request.url!.path()
                self.log.append("\(request.httpMethod!) \(path)")
                if self.down { throw URLError(.notConnectedToInternet) }
                let respond = { (status: Int, body: String) in
                    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                switch request.httpMethod! {
                case "POST":
                    self.made += 1
                    let handle = String(format: "handle%016d", self.made)
                    self.known.insert(handle)
                    return respond(201, "{\"handle\":\"\(handle)\",\"secret\":\"\(String(repeating: "s", count: 43))\"}")
                case "PUT":
                    return respond(self.known.contains(String(path.dropFirst("/handles/".count))) ? 204 : 404, "")
                default:
                    self.known.remove(String(path.dropFirst("/handles/".count)))
                    return respond(204, "")
                }
            }
        }
    }

    private final class Saved: @unchecked Sendable { var targets: [PushTarget] = [] }
    /// Where the iPhone is, which a test can move.
    private final class Clock: @unchecked Sendable { var zone = "America/New_York" }
    private final class Calls: @unchecked Sendable {
        var made: [(host: String, call: PushRegistrar.NetworkCall)] = []
        var refusing: Set<String> = []
    }

    private let relay = Relay()
    private let saved = Saved()
    private let calls = Calls()
    private let clock = Clock()
    private let token = Data(repeating: 7, count: 32)

    private func registrar() -> PushRegistrar {
        let saved = saved, calls = calls, clock = clock
        return PushRegistrar(relay: PushRelay(origin: URL(string: "https://push.example.net")!, transport: relay.transport),
                             app: "org.danromero.fatline.dev",
                             store: .init(load: { saved.targets }, save: { saved.targets = $0 }),
                             zone: { clock.zone }) { host, call in
            if calls.refusing.contains(host) { throw NetworkError.server(status: 400, message: "No.") }
            calls.made.append((host, call))
        }
    }

    private func network(_ host: String, _ name: String? = nil, status: NetworkMembership.Status = .approved,
                         choices: PushChoices? = nil, admin: Bool = false) -> NetworkMembership {
        var membership = NetworkMembership(host: host, fid: 3, key: Data(repeating: 1, count: 32), issued: 0, approval: "", status: status, name: name)
        membership.pushChoices = choices
        membership.isAdmin = admin
        return membership
    }

    func testEachJoinedNetworkGetsItsOwnHandleAndKey() async {
        await registrar().sync(token: token, networks: [network("pine.example", "Pine Street"), network("cabin.example", "Cabin"),
                                                        network("orchard.example", status: .pending)])
        XCTAssertEqual(saved.targets.map(\.host), ["pine.example", "cabin.example"], "Only networks that let you in")
        XCTAssertEqual(saved.targets.map(\.name), ["Pine Street", "Cabin"])
        XCTAssertNotEqual(saved.targets[0].handle, saved.targets[1].handle)
        XCTAssertNotEqual(saved.targets[0].key, saved.targets[1].key)
        XCTAssertEqual(calls.made.map(\.host), ["pine.example", "cabin.example"])
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]))
    }

    func testALaterLaunchOnlyRefreshes() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        relay.log = []
        calls.made = []
        await registrar.sync(token: token, networks: [network("pine.example", "Pine Street")])
        XCTAssertEqual(relay.log, ["PUT /handles/handle0000000000000001"])
        XCTAssertTrue(calls.made.isEmpty, "The network already has the handle")
        XCTAssertEqual(saved.targets.first?.name, "Pine Street", "A renamed network shows its new name")
    }

    func testAHandleTheRelayForgotIsMadeAgainAndTheNetworkTold() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        let key = saved.targets[0].key
        relay.known = []
        calls.made = []
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertEqual(saved.targets[0].handle.handle, "handle0000000000000002")
        XCTAssertEqual(saved.targets[0].key, key, "The key stays; only the handle changed")
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]))
    }

    func testANetworkNoLongerJoinedIsDroppedAtTheRelay() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example"), network("cabin.example")])
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertEqual(saved.targets.map(\.host), ["pine.example"])
        XCTAssertTrue(relay.log.contains("DELETE /handles/handle0000000000000002"))
    }

    func testOneNetworkFailingDoesntStopTheOthers() async {
        calls.refusing = ["cabin.example"]
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("cabin.example"), network("pine.example")])
        XCTAssertEqual(saved.targets.map(\.host), ["pine.example"], "Cabin is tried again next launch")
        relay.down = true
        await registrar.sync(token: token, networks: [network("cabin.example"), network("pine.example")])
        XCTAssertEqual(saved.targets.map(\.host), ["pine.example"], "Not reaching the relay keeps what's saved")
    }

    func testAnotherTimeZoneTellsTheNetwork() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertEqual(saved.targets[0].zone, "America/New_York")
        XCTAssertEqual(saved.targets[0].pushFields["tz"] as? String, "America/New_York")
        calls.made = []
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertTrue(calls.made.isEmpty, "The same zone, so nothing to tell")
        clock.zone = "Europe/Lisbon"
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertEqual(saved.targets[0].zone, "Europe/Lisbon")
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]))
    }

    func testATargetSavedWithoutAZoneTellsTheNetworkOnce() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        saved.targets[0].zone = nil
        calls.made = []
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertEqual(saved.targets[0].zone, "America/New_York")
        XCTAssertEqual(calls.made.count, 1)
    }

    func testChoosingTellsTheNetwork() async throws {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        calls.made = []
        relay.log = []
        try await registrar.apply(network("pine.example", choices: PushChoices(level: .replies)), token: token)
        XCTAssertEqual(saved.targets[0].choices.level, .replies)
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]))
        XCTAssertTrue(relay.log.isEmpty, "The same handle, so the relay isn't asked")
    }

    func testChoicesMadeBeforeTheTokenGoAtTheNextLaunch() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        calls.made = []
        await registrar.sync(token: token, networks: [network("pine.example", choices: PushChoices(level: .replies))])
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]))
        XCTAssertEqual(saved.targets[0].choices.level, .replies)
    }

    func testOffForgetsTheHandleOnBothSides() async throws {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example")])
        calls.made = []
        try await registrar.apply(network("pine.example", choices: PushChoices(level: .off)), token: token)
        XCTAssertTrue(saved.targets.isEmpty)
        XCTAssertTrue(relay.known.isEmpty)
        XCTAssertEqual(calls.made.first?.call, .remove)
        relay.log = []
        await registrar.sync(token: token, networks: [network("pine.example", choices: PushChoices(level: .off))])
        XCTAssertTrue(relay.log.isEmpty, "Off stays off at the next launch")
        XCTAssertTrue(saved.targets.isEmpty)
    }

    func testAnAdminsOffStillHearsRequestsAndReports() async throws {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example", admin: true)])
        calls.made = []
        try await registrar.apply(network("pine.example", choices: PushChoices(level: .off), admin: true), token: token)
        XCTAssertEqual(saved.targets.first?.choices.level, .off)
        XCTAssertEqual(calls.made.first?.call, .set(saved.targets[0]), "The network sends only requests and reports")
        try await registrar.apply(network("pine.example", choices: PushChoices(level: .off, requests: false, reports: false), admin: true), token: token)
        XCTAssertTrue(saved.targets.isEmpty, "Nothing left to hear")
    }

    func testOnAgainAfterOffMakesANewHandle() async throws {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example", choices: PushChoices(level: .off))])
        XCTAssertTrue(saved.targets.isEmpty)
        try await registrar.apply(network("pine.example", choices: PushChoices(level: .all)), token: token)
        XCTAssertEqual(saved.targets.map(\.host), ["pine.example"])
        XCTAssertEqual(calls.made.last?.call, .set(saved.targets[0]))
    }

    func testTurningOnWithoutATokenSaysSo() async {
        do {
            try await registrar().apply(network("pine.example"), token: nil)
            XCTFail("Expected noToken")
        } catch {
            XCTAssertEqual(error as? PushRegistrar.Problem, .noToken)
        }
    }

    func testAHandleTheNetworkWouldntTakeIsDroppedAtTheRelay() async {
        calls.refusing = ["pine.example"]
        await registrar().sync(token: token, networks: [network("pine.example")])
        XCTAssertTrue(saved.targets.isEmpty)
        XCTAssertTrue(relay.known.isEmpty, "No handle left at the relay with nobody to send to it")
    }

    func testAWaitingRequestKeepsTheHandleItsJoinCarried() async throws {
        let registrar = registrar()
        let target = try await registrar.prepare(host: "orchard.example", name: "orchard.example", token: token)
        XCTAssertTrue(saved.targets.isEmpty, "Kept only once the network has it")
        try registrar.keep(target)
        relay.log = []
        await registrar.sync(token: token, networks: [network("orchard.example", status: .pending)])
        XCTAssertEqual(saved.targets, [target])
        XCTAssertEqual(relay.log, ["PUT /handles/\(target.handle.handle)"], "Refreshed, so it doesn't age out while waiting")
        XCTAssertTrue(calls.made.isEmpty, "A waiting request has no session to tell")
        await registrar.sync(token: token, networks: [network("orchard.example", "Orchard")])
        XCTAssertEqual(saved.targets.first?.handle, target.handle, "Let in: the same handle, which the network already has")
        XCTAssertEqual(saved.targets.first?.name, "Orchard")
        XCTAssertTrue(calls.made.isEmpty)
    }

    func testAWaitingHandleTheRelayForgotGoes() async throws {
        let registrar = registrar()
        try registrar.keep(try await registrar.prepare(host: "orchard.example", name: "orchard.example", token: token))
        relay.known = []
        await registrar.sync(token: token, networks: [network("orchard.example", status: .pending)])
        XCTAssertTrue(saved.targets.isEmpty)
    }

    func testARefusedRequestsHandleGoes() async throws {
        let registrar = registrar()
        try registrar.keep(try await registrar.prepare(host: "orchard.example", name: "orchard.example", token: token))
        await registrar.sync(token: token, networks: [network("orchard.example", status: .refused)])
        XCTAssertTrue(saved.targets.isEmpty)
        XCTAssertTrue(relay.known.isEmpty)
    }

    func testNothingChangesWhenTheStoreCantBeRead() async {
        struct Locked: Error {}
        let registrar = PushRegistrar(relay: PushRelay(origin: URL(string: "https://push.example.net")!, transport: relay.transport),
                                      app: "org.danromero.fatline.dev",
                                      store: .init(load: { throw Locked() }, save: { _ in XCTFail("Saved over what couldn't be read") })) { _, _ in }
        await registrar.sync(token: token, networks: [network("pine.example")])
        XCTAssertTrue(relay.log.isEmpty)
    }

    func testStoppingCleansUpBothSides() async {
        let registrar = registrar()
        await registrar.sync(token: token, networks: [network("pine.example"), network("cabin.example")])
        calls.made = []
        await registrar.stop("pine.example")
        await registrar.stop("cabin.example", tellNetwork: false)
        XCTAssertTrue(saved.targets.isEmpty)
        XCTAssertTrue(relay.known.isEmpty)
        XCTAssertEqual(calls.made.map(\.host), ["pine.example"])
        XCTAssertEqual(calls.made.first?.call, .remove)
    }
}
