import CryptoKit
import Foundation

/// The relay at `push.fatline.tech` that passes networks' sealed notes to Apple (push/README.md). The
/// phone gives it the device token once per network and gets back a random handle and its secret; the
/// network only ever learns the handle. design/push-notifications-plan.md, "How it travels".
struct PushRelay: Sendable {
    typealias Transport = NetworkClient.Transport

    static let standard = PushRelay(origin: URL(string: "https://push.fatline.tech")!)

    /// Where this device hears from one network. Kept beside `PushTarget`, which the extension reads too.
    typealias Handle = PushHandle

    /// Apple's sandbox for Debug builds, production for TestFlight and the App Store.
    enum Environment: String, Sendable {
        case sandbox, production

        static var current: Environment {
            #if DEBUG
            .sandbox
            #else
            .production
            #endif
        }
    }

    enum Problem: LocalizedError, Equatable {
        /// The relay turned the request down, with its words.
        case refused(status: Int, message: String)
        case unreadable
        case unreachable

        var errorDescription: String? {
            switch self {
            case .refused(_, let message): message
            case .unreadable: "The notification relay sent something Fatline couldn’t read."
            case .unreachable: "Couldn’t reach the notification relay."
            }
        }
    }

    let origin: URL
    var transport: Transport = { try await HTTP.loadResponse($0) }

    /// The relay as the network is told it, without a trailing slash.
    var address: String { origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString }

    /// `POST /handles`: a new handle for this device token. One per network, so networks can't tell
    /// they share a phone.
    func register(token: Data, environment: Environment = .current, app: String) async throws -> Handle {
        let (data, response) = try await send("POST", "handles", json: ["token": Self.hex(token), "env": environment.rawValue, "app": app])
        guard response.statusCode == 201 else { throw Self.problem(response.statusCode, data) }
        guard let handle = try? JSONDecoder().decode(Handle.self, from: data), handle.isWellFormed else { throw Problem.unreadable }
        return handle
    }

    /// `PUT /handles/{handle}` with this launch's token, which also counts as use so a quiet network's
    /// handle doesn't age out. False when the relay no longer has the handle: make a new one, and give it
    /// to the network.
    func refresh(_ handle: Handle, token: Data) async throws -> Bool {
        guard handle.isWellFormed else { return false }
        let (data, response) = try await send("PUT", "handles/\(handle.handle)", json: ["token": Self.hex(token)], secret: handle.secret)
        if response.statusCode == 404 { return false }
        guard response.statusCode == 204 else { throw Self.problem(response.statusCode, data) }
        return true
    }

    /// `DELETE /handles/{handle}`: this device stops hearing from that network. Gone already counts as done.
    func remove(_ handle: Handle) async throws {
        guard handle.isWellFormed else { return }
        let (data, response) = try await send("DELETE", "handles/\(handle.handle)", json: nil, secret: handle.secret)
        guard response.statusCode == 204 || response.statusCode == 404 else { throw Self.problem(response.statusCode, data) }
    }

    /// The device token as the relay takes it: lowercase hex, no prefix. Tokens vary in length (the
    /// Simulator's are 80 bytes); the relay takes 32 to 100.
    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    private func send(_ method: String, _ path: String, json: [String: String]?, secret: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        do {
            return try await transport(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Problem.unreachable
        }
    }

    private static func problem(_ status: Int, _ data: Data) -> Problem {
        struct Answer: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(Answer.self, from: data))?.message
        return .refused(status: status, message: message ?? "The notification relay answered \(status).")
    }
}

extension PushTarget {
    static func make(host: String, name: String, relay: PushRelay, handle: PushRelay.Handle,
                     choices: PushChoices = PushChoices(), zone: String = TimeZone.current.identifier) -> PushTarget {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return PushTarget(host: host, name: name, relay: relay.address, handle: handle, key: key, choices: choices, zone: zone)
    }

    /// `push` in `POST /join` and the start of `PUT /me/push`: the relay, the handle, the key as `0x`
    /// and 64 hex digits, and the time zone.
    var joinFields: [String: Any] {
        var fields: [String: Any] = ["relay": relay, "handle": handle.handle, "key": key.hex]
        if let zone { fields["tz"] = zone }
        return fields
    }

    /// The whole body of `PUT /me/push`.
    var pushFields: [String: Any] {
        joinFields.merging(["level": choices.level.rawValue, "requests": choices.requests, "reports": choices.reports]) { $1 }
    }
}
