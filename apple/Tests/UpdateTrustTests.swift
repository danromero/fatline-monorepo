import XCTest
@testable import Fatline

#if os(macOS)
/// An update that fails its signature or version check stops with a message. Only a copy whose folder
/// can't be written goes to installing by hand.
final class UpdateTrustTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "UpdateTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An app bundle with no signature, as a tampered or stand-in download would be.
    private func unsignedApp(version: String) throws -> URL {
        let app = folder.appending(path: "Fatline.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.danromero.fatline", "CFBundleExecutable": "Fatline",
            "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/Fatline")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    func testAnUnsignedDownloadIsUntrusted() throws {
        let app = try unsignedApp(version: "99.0.0")
        XCTAssertThrowsError(try UpdateCheck.check(app, current: "0.3.0")) { error in
            XCTAssertEqual(error as? UpdateCheck.UpdateFailure, .untrusted)
        }
    }

    func testAnUntrustedDownloadIsNeverInstalledByHand() {
        for failure in [UpdateCheck.UpdateFailure.untrusted, .notNewer, .download] {
            XCTAssertFalse(UpdateCheck.notice(for: failure).opensDownload, "\(failure)")
        }
    }

    func testAnUntrustedDownloadSaysWhy() {
        let notice = UpdateCheck.notice(for: .untrusted)
        XCTAssertEqual(notice.title, "Fatline didn’t install this update")
        XCTAssertTrue(notice.detail.contains("isn’t signed by Fatline’s developer"))
        XCTAssertFalse(notice.detail.contains("drag"))
        XCTAssertTrue(UpdateCheck.notice(for: .notNewer).detail.contains("isn’t newer"))
    }

    func testOnlyAReadOnlyFolderInstallsByHand() {
        let notice = UpdateCheck.notice(for: .readOnly)
        XCTAssertTrue(notice.opensDownload)
        XCTAssertTrue(notice.detail.contains("drag Fatline to Applications"))
    }

    func testAReadOnlyFolderCantBeReplaced() throws {
        let app = try unsignedApp(version: "0.3.0")
        XCTAssertTrue(UpdateCheck.canReplace(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(UpdateCheck.canReplace(app))
    }
}
#endif
