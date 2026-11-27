import Foundation
@testable import SweetMX
import XCTest

/// Proves which apps may be removed using scripted seams only, so no test reads a real app or the
/// real home folder.
final class UninstallTargetResolverTests: XCTestCase {
    private enum Fixture {
        static let folder = "/Applications"
        static let bundlePath = "/Applications/Sample.app"
        static let ownID = "dev.sweetmx.test"
        static let thirdPartyID = "com.example.sample"
        static let plistKey = "CFBundleIdentifier"
        static let displayKey = "CFBundleDisplayName"
        static let nameKey = "CFBundleName"
        static let infoSuffix = "/Contents/Info.plist"
        static let oversizeBytes = 1_048_577
    }

    private var fileSystem: MockFileSystem!
    private var identity: MockCodeIdentity!

    override func setUp() {
        super.setUp()
        fileSystem = MockFileSystem()
        identity = MockCodeIdentity()
        fileSystem.writableDirectories.insert(Fixture.folder)
    }

    private func install(path: String = Fixture.bundlePath, info: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        fileSystem.addFile(at: path + Fixture.infoSuffix, contents: data)
    }

    private func resolver(ownBundleID: String? = Fixture.ownID) -> UninstallTargetResolver {
        UninstallTargetResolver(fileSystem: fileSystem, codeIdentity: identity, ownBundleID: ownBundleID)
    }

    private func resolve(path: String = Fixture.bundlePath) -> Result<UninstallTarget, UninstallRefusal> {
        resolver().resolve(bundlePath: path)
    }

    func testResolvesSignedThirdPartyApp() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID, Fixture.displayKey: "Sample Pro"])
        identity.setIdentifier(Fixture.thirdPartyID, forBundleAt: URL(fileURLWithPath: Fixture.bundlePath))

        let target = try resolve().get()

        XCTAssertEqual(target.bundleID, Fixture.thirdPartyID)
        XCTAssertEqual(target.displayName, "Sample Pro")
        XCTAssertEqual(target.bundleURL.path, Fixture.bundlePath)
        XCTAssertTrue(target.identityConfirmed)
        XCTAssertFalse(target.needsFinder)
    }

    func testRefusesSymlinkedAppBeforeReadingAnything() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])
        fileSystem.symbolicLinks.insert(Fixture.bundlePath)

        XCTAssertEqual(resolve(), .failure(.symlinkedApp))
        XCTAssertTrue(fileSystem.contentsAtPathCalls.isEmpty)
    }

    func testRefusesAppThatResolvesUnderSystem() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])
        fileSystem.resolvedPaths[Fixture.bundlePath] = URL(fileURLWithPath: "/System/Applications/Sample.app")

        XCTAssertEqual(resolve(), .failure(.systemApp))
    }

    func testRefusesRequiredAppleApp() throws {
        try install(info: [Fixture.plistKey: "com.apple.Safari"])

        XCTAssertEqual(resolve(), .failure(.requiredAppleApp))
    }

    func testAllowsListedAppleApps() throws {
        for id in ["com.apple.dt.Xcode", "com.apple.iWork.Pages", "com.apple.iMovieApp", "com.apple.garageband10"] {
            try install(info: [Fixture.plistKey: id])
            XCTAssertNoThrow(try resolve().get(), id)
        }
    }

    func testAppleLookalikeIsNotAllowlisted() throws {
        try install(info: [Fixture.plistKey: "com.apple.iWork.PagesX"])

        XCTAssertEqual(resolve(), .failure(.requiredAppleApp))
    }

    func testRefusesSweetMXItself() throws {
        try install(info: [Fixture.plistKey: Fixture.ownID])

        XCTAssertEqual(resolve(), .failure(.sweetMXItself))
    }

    func testNoOwnBundleIDRefusesNothingAsItself() throws {
        try install(info: [Fixture.plistKey: Fixture.ownID])

        XCTAssertNoThrow(try resolver(ownBundleID: nil).resolve(bundlePath: Fixture.bundlePath).get())
    }

    func testRefusesMissingInfoPlist() {
        XCTAssertEqual(resolve(), .failure(.unreadableBundleID))
    }

    func testRefusesOversizeInfoPlist() {
        fileSystem.addFile(at: Fixture.bundlePath + Fixture.infoSuffix, contents: Data(count: Fixture.oversizeBytes))

        XCTAssertEqual(resolve(), .failure(.unreadableBundleID))
    }

    func testRefusesInfoPlistWithoutBundleID() throws {
        try install(info: [Fixture.nameKey: "Sample"])

        XCTAssertEqual(resolve(), .failure(.unreadableBundleID))
    }

    func testRefusesMalformedBundleID() throws {
        try install(info: [Fixture.plistKey: "a/b.c"])

        XCTAssertEqual(resolve(), .failure(.unreadableBundleID))
    }

    func testIdentityUnconfirmedWhenSignatureDiffers() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])
        identity.setIdentifier("com.other.vendor", forBundleAt: URL(fileURLWithPath: Fixture.bundlePath))

        XCTAssertFalse(try resolve().get().identityConfirmed)
    }

    func testIdentityUnconfirmedWhenUnsigned() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])

        XCTAssertFalse(try resolve().get().identityConfirmed)
    }

    func testNeedsFinderWhenParentNotWritable() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])
        fileSystem.writableDirectories.removeAll()

        XCTAssertTrue(try resolve().get().needsFinder)
        XCTAssertEqual(fileSystem.isWritableDirectoryCalls.map(\.path), [Fixture.folder])
    }

    func testDisplayNameFallsBackToBundleNameThenFileName() throws {
        try install(info: [Fixture.plistKey: Fixture.thirdPartyID, Fixture.nameKey: "Bundle Name"])
        XCTAssertEqual(try resolve().get().displayName, "Bundle Name")

        try install(info: [Fixture.plistKey: Fixture.thirdPartyID])
        XCTAssertEqual(try resolve().get().displayName, "Sample")
    }

    func testIsWellFormed() {
        XCTAssertTrue(UninstallTargetResolver.isWellFormed(bundleID: "md.obsidian"))
        XCTAssertTrue(UninstallTargetResolver.isWellFormed(bundleID: "com.my-co.app_2"))
        for bad in ["Slack", "a..b", "a/b.c", "", ".a.b", "a.b."] {
            XCTAssertFalse(UninstallTargetResolver.isWellFormed(bundleID: bad), bad)
        }
    }
}
