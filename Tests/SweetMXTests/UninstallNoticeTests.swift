import Foundation
@testable import SweetMX
import XCTest

/// Proves which warnings and blocks the sheet gets for an app, with scripted seams only, so no test
/// reads a real app or the real home folder.
final class UninstallNoticeTests: XCTestCase {
    private enum Fixture {
        static let bundlePath = "/Applications/Sample Pro.app"
        static let appFileName = "Sample Pro.app"
        static let bundleID = "com.x.app"
        static let extensionsPath = "/Applications/Sample Pro.app/Contents/Library/SystemExtensions"
        static let caskroom = "/opt/homebrew/Caskroom"
        static let token = "sample-pro"
        static let version = "1.0"
        static let dockerID = "com.docker.docker"
        static let karabinerID = "org.pqrs.Karabiner-Elements.Settings"
        static let snitchID = "at.obdev.littlesnitch"
        static let dockerPage = "https://docs.docker.com/desktop/uninstall/"
        static let karabinerPage = "https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/"
        static let snitchPage = "https://help.obdev.at/littlesnitch6/intro-uninstall"
    }

    private var fileSystem: MockFileSystem!

    override func setUp() {
        super.setUp()
        fileSystem = MockFileSystem()
    }

    private func target(bundleID: String = Fixture.bundleID) -> UninstallTarget {
        UninstallTarget(
            bundleURL: URL(fileURLWithPath: Fixture.bundlePath),
            displayName: "Sample Pro",
            bundleID: bundleID,
            identityConfirmed: true,
            needsFinder: false
        )
    }

    private func addSystemExtension() {
        let folder = URL(fileURLWithPath: Fixture.extensionsPath)
        fileSystem.directoryContents[folder] = [folder.appendingPathComponent("Sample.systemextension")]
    }

    /// Scripts the Caskroom layout Homebrew leaves so `HomebrewReceipt.find` accepts it.
    private func receipt() throws -> HomebrewReceipt {
        let root = URL(fileURLWithPath: Fixture.caskroom)
        let tokenURL = root.appendingPathComponent(Fixture.token)
        let versionURL = tokenURL.appendingPathComponent(Fixture.version)
        let linkURL = versionURL.appendingPathComponent(Fixture.appFileName)
        let json = try JSONSerialization.data(withJSONObject: ["uninstall_artifacts": [["app": [Fixture.appFileName]]]])
        fileSystem.directoryContents[root] = [tokenURL]
        fileSystem.directoryContents[tokenURL] = [tokenURL.appendingPathComponent(".metadata"), versionURL]
        fileSystem.directoryContents[versionURL] = [linkURL]
        fileSystem.fileContents["\(tokenURL.path)/.metadata/INSTALL_RECEIPT.json"] = json
        fileSystem.symbolicLinks.insert(linkURL.path)
        fileSystem.resolvedPaths[linkURL.path] = URL(fileURLWithPath: Fixture.bundlePath)
        return try XCTUnwrap(HomebrewReceipt.find(for: target(), fileSystem: fileSystem))
    }

    private func notices(_ target: UninstallTarget, homebrew: HomebrewReceipt? = nil) -> [UninstallNotice] {
        UninstallNotice.notices(for: target, homebrew: homebrew, fileSystem: fileSystem)
    }

    private func page(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    func testPlainAppHasNoNotices() {
        XCTAssertTrue(notices(target()).isEmpty)
    }

    func testSystemExtensionBlocks() {
        addSystemExtension()
        let result = notices(target())
        XCTAssertEqual(result, [.blocked(reason: .systemExtension, page: nil)])
        XCTAssertTrue(result.allSatisfy(\.blocksRemoval))
    }

    func testEmptySystemExtensionsFolderDoesNotBlock() {
        fileSystem.directoryContents[URL(fileURLWithPath: Fixture.extensionsPath)] = []
        XCTAssertTrue(notices(target()).isEmpty)
    }

    func testSystemExtensionListingIsOneEntryDeep() {
        addSystemExtension()
        _ = notices(target())
        XCTAssertEqual(fileSystem.contentsOfDirectoryCalls, [URL(fileURLWithPath: Fixture.extensionsPath)])
    }

    func testDockerDesktopPointsToItsUninstaller() throws {
        XCTAssertEqual(
            notices(target(bundleID: Fixture.dockerID)),
            try [.vendorUninstaller(vendor: "Docker Desktop", page: page(Fixture.dockerPage))]
        )
    }

    func testKarabinerPrefixPointsToItsUninstaller() throws {
        XCTAssertEqual(
            notices(target(bundleID: Fixture.karabinerID)),
            try [.vendorUninstaller(vendor: "Karabiner-Elements", page: page(Fixture.karabinerPage))]
        )
    }

    func testLittleSnitchBlocks() throws {
        let result = notices(target(bundleID: Fixture.snitchID))
        XCTAssertEqual(result, try [.blocked(reason: .securitySoftware, page: page(Fixture.snitchPage))])
        XCTAssertTrue(result.allSatisfy(\.blocksRemoval))
    }

    func testVendorMatchIsCaseSensitiveAndExactForDocker() {
        XCTAssertTrue(notices(target(bundleID: "COM.DOCKER.DOCKER")).isEmpty)
        XCTAssertTrue(notices(target(bundleID: Fixture.dockerID + ".helper")).isEmpty)
        XCTAssertTrue(notices(target(bundleID: "org.pqrs.karabiner")).isEmpty)
    }

    func testHomebrewCommandUsesTheToken() throws {
        let result = try notices(target(), homebrew: receipt())
        XCTAssertEqual(result, [.homebrew(command: "brew uninstall --cask \(Fixture.token)")])
        XCTAssertFalse(result[0].blocksRemoval)
    }

    func testVendorNoticeDoesNotBlock() {
        XCTAssertFalse(notices(target(bundleID: Fixture.dockerID)).contains { $0.blocksRemoval })
    }

    func testBlockWinsOverOtherNotices() throws {
        addSystemExtension()
        let result = try notices(target(bundleID: Fixture.snitchID), homebrew: receipt())
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].blocksRemoval)
        XCTAssertTrue(result[1].blocksRemoval)
        XCTAssertFalse(result[2].blocksRemoval)
        XCTAssertTrue(result.contains { $0.blocksRemoval })
    }

    func testAllNoticesAreReturned() throws {
        addSystemExtension()
        let result = try notices(target(bundleID: Fixture.dockerID), homebrew: receipt())
        XCTAssertEqual(result, try [
            .blocked(reason: .systemExtension, page: nil),
            .vendorUninstaller(vendor: "Docker Desktop", page: page(Fixture.dockerPage)),
            .homebrew(command: "brew uninstall --cask \(Fixture.token)"),
        ])
    }
}
