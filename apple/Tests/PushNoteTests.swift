import CryptoKit
import XCTest
@testable import Fatline

/// Sealed notes open as the network seals them, and the app writes the words, not the network.
final class PushNoteTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let key: String
        let nonce: String
        let plaintext: String
        let sealed: String
    }

    /// The vectors the network's own tests use (network/test/push-vectors.json).
    private func vectors() throws -> [Vector] {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../network/test/push-vectors.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("network/ isn't next to apple/.") }
        struct File: Decodable { let vectors: [Vector] }
        return try JSONDecoder().decode(File.self, from: data).vectors
    }

    private func key(_ hex: String) throws -> SymmetricKey {
        SymmetricKey(data: try XCTUnwrap(Data(hex: hex)))
    }

    private let network = "Pine Street"
    private let sampleKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

    /// Seals as the network does, with a random nonce.
    private func seal(_ json: String, key: SymmetricKey? = nil) throws -> String {
        let box = try AES.GCM.seal(Data(json.utf8), using: key ?? sampleKey)
        return try XCTUnwrap(box.combined).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func note(_ fields: String) throws -> PushNote {
        try XCTUnwrap(PushNote.open(try seal("{\"v\":1,\(fields)}"), key: sampleKey))
    }

    private func body(_ fields: String) throws -> String {
        try note(fields).words(network: network).body
    }

    // MARK: Opening

    func testEveryVectorOpensToItsPlaintext() throws {
        for vector in try vectors() {
            let opened = try PushNote.unseal(vector.sealed, key: try key(vector.key))
            XCTAssertEqual(opened, Data(vector.plaintext.utf8), vector.name)
        }
    }

    func testSealingWithTheVectorsNonceGivesTheSameNote() throws {
        for vector in try vectors() {
            let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hex: vector.nonce)))
            let box = try AES.GCM.seal(Data(vector.plaintext.utf8), using: try key(vector.key), nonce: nonce)
            let sealed = try XCTUnwrap(box.combined).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(sealed, vector.sealed, vector.name)
        }
    }

    func testTheVectorNotesReadAsTheyShould() throws {
        let notes = try vectors().filter { $0.plaintext.hasPrefix("{") }
        XCTAssertEqual(notes.count, 3)
        let words = try notes.map { try XCTUnwrap(PushNote.open($0.sealed, key: try key($0.key)), $0.name).words(network: network) }
        XCTAssertEqual(words.map(\.title), [network, network, network])
        XCTAssertEqual(words.map(\.body), ["@helen replied: Dinner at 7? @sana",
                                           "3 new posts from mika, sana, and dave",
                                           "You’re in."])
    }

    func testAChangedByteOrAnotherKeyDoesntOpen() throws {
        let vector = try XCTUnwrap(try vectors().first { $0.plaintext.hasPrefix("{") })
        var changed = Array(vector.sealed)
        changed[20] = changed[20] == "A" ? "B" : "A"
        XCTAssertNil(PushNote.open(String(changed), key: try key(vector.key)))
        XCTAssertNil(PushNote.open(vector.sealed, key: SymmetricKey(size: .bits256)))
        XCTAssertNil(PushNote.open(vector.sealed, key: SymmetricKey(size: .bits128)))
    }

    func testOnlyBase64URLOfAPlausibleLengthOpens() throws {
        let sealed = try seal("{\"v\":1,\"kind\":\"approved\",\"fid\":3}")
        XCTAssertNotNil(PushNote.open(sealed, key: sampleKey))
        XCTAssertNil(PushNote.open(sealed + "=", key: sampleKey), "padding isn't base64url")
        XCTAssertNil(PushNote.open(sealed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "+", key: sampleKey))
        XCTAssertNil(PushNote.open("", key: sampleKey))
        XCTAssertNil(PushNote.open("AAAA", key: sampleKey), "shorter than a nonce and a tag")
        XCTAssertNil(PushNote.open(String(repeating: "A", count: PushNote.maxSealedCharacters + 4), key: sampleKey))
    }

    func testAnUnknownVersionOrKindDoesntOpen() throws {
        XCTAssertNil(PushNote.open(try seal("{\"v\":2,\"kind\":\"reply\",\"fid\":3,\"username\":\"a\"}"), key: sampleKey))
        XCTAssertNil(PushNote.open(try seal("{\"v\":1,\"kind\":\"like\",\"fid\":3,\"username\":\"a\"}"), key: sampleKey))
        XCTAssertNil(PushNote.open(try seal("not json"), key: sampleKey))
    }

    // MARK: Words

    func testEachKindHasItsWords() throws {
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"helen\",\"text\":\"In!\""), "@helen replied: In!")
        XCTAssertEqual(try body("\"kind\":\"mention\",\"fid\":2,\"username\":\"sana\",\"text\":\"Hi @frank\""), "@sana mentioned you: Hi @frank")
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"mika\",\"text\":\"Hike at 9?\",\"count\":1"), "@mika: Hike at 9?")
        XCTAssertEqual(try body("\"kind\":\"approved\",\"fid\":2,\"username\":\"frank\",\"text\":\"\",\"post\":null,\"thread\":null"), "You’re in.")
        XCTAssertEqual(try body("\"kind\":\"request\",\"fid\":2,\"username\":\"dave\",\"text\":\"\""), "@dave asked to join")
        XCTAssertEqual(try body("\"kind\":\"report\",\"fid\":2,\"username\":\"erin\",\"text\":\"spam\""), "@erin reported a post")
        XCTAssertEqual(try body("\"kind\":\"test\",\"fid\":3,\"username\":\"dwr\",\"text\":\"\",\"post\":null,\"thread\":null"),
                       "Test notification. This iPhone hears from this network.")
    }

    func testPicturesWithoutText() throws {
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"mika\",\"text\":\"\",\"pictures\":1"), "@mika posted a picture")
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"mika\",\"text\":\"\",\"pictures\":2"), "@mika posted 2 pictures")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"helen\",\"text\":\"\",\"pictures\":1"), "@helen replied with a picture")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"helen\",\"text\":\"\",\"pictures\":0"), "@helen replied")
        XCTAssertEqual(try body("\"kind\":\"mention\",\"fid\":2,\"username\":\"sana\",\"text\":\"\",\"pictures\":1"), "@sana mentioned you")
    }

    func testNewPostsInAnHourShowAsOne() throws {
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"sana\",\"text\":\"x\",\"count\":2,\"usernames\":[\"sana\",\"mika\"]"),
                       "2 new posts from sana and mika")
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"sana\",\"text\":\"x\",\"count\":7,\"usernames\":[\"sana\"]"),
                       "7 new posts from sana")
        // Names past three, and ones the app wouldn't show, are left out.
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"a\",\"text\":\"x\",\"count\":9,\"usernames\":[\"a\",\"Fake Admin\",\"b\",\"c\"]"),
                       "9 new posts from a and b")
        XCTAssertEqual(try body("\"kind\":\"post\",\"fid\":2,\"username\":\"a\",\"text\":\"x\",\"count\":4,\"usernames\":[]"), "4 new posts")
    }

    func testTheTitleIsTheSavedNameNeverTheNotes() throws {
        let words = try note("\"kind\":\"reply\",\"fid\":2,\"username\":\"helen\",\"text\":\"hi\",\"name\":\"37 Club\",\"title\":\"Apple\"")
            .words(network: network)
        XCTAssertEqual(words.title, network)
    }

    func testANameThatIsntAUsernameShowsAsTheFID() throws {
        XCTAssertEqual(try body("\"kind\":\"approved\",\"fid\":1005,\"username\":\"!1005\""), "You’re in.")
        XCTAssertEqual(try body("\"kind\":\"request\",\"fid\":1005,\"username\":\"!1005\""), "!1005 asked to join")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":7,\"username\":\"Apple ID: verify now\",\"text\":\"hi\""), "!7 replied: hi")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":7,\"username\":\"HELEN\",\"text\":\"hi\""), "!7 replied: hi")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":7,\"text\":\"hi\""), "!7 replied: hi")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":7,\"username\":\"vitalik.eth\",\"text\":\"hi\""), "@vitalik.eth replied: hi")
    }

    func testTextLosesHiddenCharactersAndStopsAt280() throws {
        // A right-to-left override would make "gpj.exe" read backwards.
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"photo\\u202Egpj.exe\""), "@a replied: photogpj.exe")
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"line one\\nline two\""), "@a replied: line one\nline two")
        // Emoji built with joiners stay whole.
        XCTAssertEqual(try body("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"👩‍👩‍👧\""), "@a replied: 👩‍👩‍👧")
        let long = String(repeating: "é", count: 300)
        let text = try note("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"\(long)\"").text
        XCTAssertEqual(text.count, PushNote.maxTextCharacters)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testOnlyRealHashesAreKeptForTheTap() throws {
        let hash = "0x" + String(repeating: "ab", count: 20)
        let good = try note("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"x\",\"post\":\"\(hash)\",\"thread\":\"\(hash.uppercased().replacingOccurrences(of: "0X", with: "0x"))\"")
        XCTAssertEqual(good.post, hash)
        XCTAssertEqual(good.thread, hash)
        let bad = try note("\"kind\":\"reply\",\"fid\":2,\"username\":\"a\",\"text\":\"x\",\"post\":\"https://evil.example\",\"thread\":\"0x12\"")
        XCTAssertNil(bad.post)
        XCTAssertNil(bad.thread)
    }
}
