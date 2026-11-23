import Foundation

/// Keeps each network you're in told where this device hears from it: a handle at the relay per
/// network, the network's `PUT /me/push`, and cleanup when you turn one off, leave, or forget it.
/// Shared so the Mac can follow iPhone (design/push-notifications-plan.md, Phase 3). The app gives it
/// the device token at each launch; the Keychain store and the network calls are passed in, so it can
/// run against stand-ins. The app runs one call at a time, so two never save over each other.
@MainActor
final class PushRegistrar {
    /// Where targets are kept. The app's is the Keychain, readable by the notification extension.
    struct Store: Sendable {
        var load: @Sendable () throws -> [PushTarget]
        var save: @Sendable ([PushTarget]) throws -> Void
    }

    /// What the network is told, through its signed-in session.
    enum NetworkCall: Equatable, Sendable {
        case set(PushTarget)
        case remove
    }

    enum Problem: LocalizedError, Equatable {
        /// iOS hasn't given this launch a device token yet.
        case noToken

        var errorDescription: String? { "This iPhone isn’t ready for notifications yet. Try again in a moment." }
    }

    typealias Network = @Sendable (_ host: String, _ call: NetworkCall) async throws -> Void

    let relay: PushRelay
    let app: String
    private let store: Store
    private let network: Network
    /// Where this device is now, for when twice-a-day summaries go.
    private let zone: @Sendable () -> String

    init(relay: PushRelay = .standard, app: String = Bundle.main.bundleIdentifier ?? "org.danromero.fatline",
         store: Store, zone: @escaping @Sendable () -> String = { TimeZone.current.identifier }, network: @escaping Network) {
        self.relay = relay
        self.app = app
        self.store = store
        self.zone = zone
        self.network = network
    }

    /// The networks this device hears from, by host.
    var targets: [PushTarget] { (try? store.load()) ?? [] }

    /// At each launch, with the token iOS gave: every network that let you in gets a handle and is told
    /// it with your choices, handles the relay forgot are made again, and targets for networks no longer
    /// joined go. A request that's waiting keeps the handle its join carried, so it hears "You're in."
    /// One network failing doesn't stop the others; it's tried again next launch. Nothing changes if the
    /// Keychain can't be read.
    func sync(token: Data, networks: [NetworkMembership]) async {
        guard var kept = try? store.load() else { return }
        for gone in kept where !networks.contains(where: { $0.host == gone.host && $0.status != .refused }) {
            try? await relay.remove(gone.handle)
            kept.removeAll { $0.host == gone.host }
        }
        // The network can't be told a new handle until it lets you in, so one the relay forgot goes.
        for waiting in networks where waiting.status == .pending {
            guard let target = kept.first(where: { $0.host == waiting.host }),
                  (try? await relay.refresh(target.handle, token: token)) == false else { continue }
            kept.removeAll { $0.host == waiting.host }
        }
        try? store.save(kept)
        for membership in networks where membership.status == .approved {
            try? await apply(membership, token: token, refresh: true)
        }
    }

    /// Makes what this device hears from one network that let you in match its choices: a handle and
    /// `PUT /me/push`, new choices or a new time zone, or for Off, nothing at all. `refresh` also gives
    /// the relay this launch's token, making the handle again if the relay forgot it.
    func apply(_ membership: NetworkMembership, token: Data?, refresh: Bool = false) async throws {
        let host = membership.host
        let choices = membership.pushChoices ?? PushChoices()
        let existing = try store.load().first { $0.host == host }
        guard choices.hearsAnything(admin: membership.isAdmin) else {
            if existing != nil { await stop(host) }
            return
        }
        let zone = zone()
        if var target = existing {
            var tell = target.choices != choices || target.zone != zone
            target.name = membership.title
            target.choices = choices
            target.zone = zone
            if refresh, let token, try await !relay.refresh(target.handle, token: token) {
                target.handle = try await relay.register(token: token, app: app)
                tell = true
            }
            if tell { try await network(host, .set(target)) }
            try keep(target)
        } else {
            guard let token else { throw Problem.noToken }
            let target = PushTarget.make(host: host, name: membership.title, relay: relay,
                                         handle: try await relay.register(token: token, app: app), choices: choices, zone: zone)
            do {
                try await network(host, .set(target))
            } catch {
                try? await relay.remove(target.handle)
                throw error
            }
            try keep(target)
        }
    }

    /// A handle for a network you're about to ask to join, or are waiting on, for the join to carry.
    /// It's kept only once the network has it (`keep`).
    func prepare(host: String, name: String, token: Data) async throws -> PushTarget {
        PushTarget.make(host: host, name: name, relay: relay, handle: try await relay.register(token: token, app: app), zone: zone())
    }

    /// Saves a target, replacing any for the same network.
    func keep(_ target: PushTarget) throws {
        var kept = try store.load()
        kept.removeAll { $0.host == target.host }
        kept.append(target)
        try store.save(kept)
    }

    /// A prepared handle no network will use, such as after a join that was turned down.
    func discard(_ target: PushTarget) async {
        try? await relay.remove(target.handle)
    }

    /// Off, leaving, or forgetting a network: the relay drops the handle and the network forgets it.
    /// A network you already left can't be told, so `tellNetwork` is false then; the relay's handle
    /// going is enough, since the network drops a handle the relay says is gone.
    func stop(_ host: String, tellNetwork: Bool = true) async {
        guard var kept = try? store.load(), let target = kept.first(where: { $0.host == host }) else { return }
        try? await relay.remove(target.handle)
        if tellNetwork { try? await network(host, .remove) }
        kept.removeAll { $0.host == host }
        try? store.save(kept)
    }

    /// Every network, as when forgetting them all.
    func stopAll() async {
        for target in targets { await stop(target.host, tellNetwork: false) }
    }
}

extension PushKeychain {
    /// For `PushRegistrar`.
    var store: PushRegistrar.Store {
        let keychain = self
        return .init(load: { try keychain.load() }, save: { try keychain.save($0) })
    }
}
