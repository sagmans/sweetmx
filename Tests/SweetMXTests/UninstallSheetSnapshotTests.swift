import AppKit
import SnapshotTesting
@testable import SweetMX
import SwiftUI
import XCTest

/// Snapshots of the uninstall sheets in light and dark, to catch clipped copy, overlapping controls and
/// lost marks. Same rules as `SnapshotTests`: glass is swapped for a fixed background, so the
/// references cover layout, text and colors, not the material. Sizes are formatted in the machine's
/// locale, like the app does, so references are recorded on the development Mac.
@MainActor
final class UninstallSheetSnapshotTests: XCTestCase {
    private typealias Path = UninstallSheetFixture.Path

    private enum Look: String, CaseIterable {
        case dark
        case light

        var appearanceName: NSAppearance.Name {
            self == .dark ? .darkAqua : .aqua
        }
    }

    private enum Fixture {
        static let localeIdentifier = "en_US"
        static let permissionCode = 513
        /// Height used for the first layout pass, before the sheet reports its own.
        static let initialHeight: CGFloat = 600
    }

    /// Same tolerance as the launcher references.
    private static let precision: Float = 0.99
    private static let perceptualPrecision: Float = 0.98
    private static let settleTimeout: TimeInterval = 5
    private static let settlePollInterval: TimeInterval = 0.05
    private static let settleStableLooks = 3

    private var world: UninstallSheetFixture!

    private var recordMode: SnapshotTestingConfiguration.Record? {
        let value = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"]
        return value == "1" || value == "true" ? .all : nil
    }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] == "true",
            "Snapshot tests are skipped in CI due to environment-specific rendering differences."
        )
        world = UninstallSheetFixture()
    }

    override func tearDown() async throws {
        world?.launcher.hide()
        world = nil
        try await super.tearDown()
    }

    // MARK: - Rendering

    /// Hosts the sheet content at its own height, in a window the caller keeps alive for the render.
    private func host(_ model: UninstallSheetModel, look: Look) -> NSWindow {
        let root = UninstallSheetView(model: model)
            .background(DesignTokens.Palette.snapshotSurface)
            .environment(\.launcherSnapshotMode, true)
            .environment(\.locale, Locale(identifier: Fixture.localeIdentifier))
            // The test window is never key; this draws buttons as in the focused sheet.
            .environment(\.controlActiveState, .key)
        let hostView = NSHostingView(rootView: root)
        hostView.sizingOptions = []
        hostView.frame = CGRect(x: 0, y: 0, width: DesignTokens.Metrics.uninstallSheetWidth, height: Fixture.initialHeight)
        hostView.appearance = NSAppearance(named: look.appearanceName)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .sRGB
        window.contentView = hostView
        return window
    }

    /// Waits until the image stops changing, then fits the view to the height the sheet asked for, as
    /// the prompt fits the sheet window, and waits again.
    private func settle(_ view: NSView, model: UninstallSheetModel) {
        var reported: CGSize?
        model.onSizeChange = { reported = $0 }
        waitForStableImage(view)
        if let reported {
            view.setFrameSize(reported)
        }
        waitForStableImage(view)
    }

    private func waitForStableImage(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: Self.settleTimeout)
        var previous: Data?
        var stableLooks = 0
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.settlePollInterval))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let current = rep.representation(using: .tiff, properties: [:])
            stableLooks = current == previous ? stableLooks + 1 : 0
            previous = current
            if stableLooks >= Self.settleStableLooks {
                return
            }
        }
        XCTFail("The sheet did not reach a stable image within \(Self.settleTimeout) s", file: file, line: line)
    }

    /// Snapshots one scenario in dark and light. `makeModel` runs per look so each render starts fresh.
    /// Every sheet must fit the launcher panel, so the height is checked as well as the image.
    private func assertSheet(
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line,
        makeModel: () async throws -> UninstallSheetModel
    ) async throws {
        for look in Look.allCases {
            let model = try await makeModel()
            let window = host(model, look: look)
            let view = try XCTUnwrap(window.contentView)
            settle(view, model: model)
            XCTAssertLessThanOrEqual(view.frame.height, DesignTokens.Metrics.uninstallSheetMaxHeight, file: file, line: line)
            assertSnapshot(
                of: view,
                as: .image(precision: Self.precision, perceptualPrecision: Self.perceptualPrecision),
                named: look.rawValue,
                record: recordMode,
                file: file,
                testName: testName,
                line: line
            )
        }
    }

    /// A fresh world per look, so one render's ticks never leak into the next.
    private func freshWorld(_ arrange: (UninstallSheetFixture) throws -> Void) rethrows -> UninstallSheetFixture {
        world?.launcher.hide()
        world = UninstallSheetFixture()
        try arrange(world)
        return world
    }

    // MARK: - Scenarios

    func testSnapshotAppOnly() async throws {
        try await assertSheet {
            let world = freshWorld {
                $0.addBundleIDItems()
                $0.addNameMatch()
            }
            return await world.loadedModel()
        }
    }

    /// Every selectable row ticked, with a locked container, a name match and a Homebrew row. No cache
    /// row, so the whole list fits without scrolling and the locked row is in the reference.
    func testSnapshotAllRelated() async throws {
        try await assertSheet {
            let world = try freshWorld {
                $0.put(Path.settings, size: UninstallSheetFixture.Size.settings)
                $0.addNameMatch()
                $0.addContainer()
                try $0.addHomebrew()
            }
            let model = await world.loadedModel()
            model.setChoice(.everything)
            model.moveFocus(by: 1)
            return model
        }
    }

    /// More rows than fit, under a Homebrew notice: the list scrolls and the sheet keeps the panel height.
    func testSnapshotManyRowsFitThePanel() async throws {
        try await assertSheet {
            let world = try freshWorld {
                $0.addEveryBundleIDItem()
                $0.addContainer()
                try $0.addHomebrew()
            }
            return await world.loadedModel()
        }
    }

    func testSnapshotBlockedByNotice() async throws {
        try await assertSheet {
            let world = freshWorld {
                $0.addBundleIDItems()
                $0.addSystemExtension()
            }
            return await world.loadedModel()
        }
    }

    func testSnapshotNeedsAdministrator() async throws {
        try await assertSheet {
            let world = freshWorld {
                $0.addBundleIDItems()
                $0.makeAppFolderReadOnly()
            }
            return await world.loadedModel()
        }
    }

    func testSnapshotResultWithOneFailure() async throws {
        try await assertSheet {
            let world = freshWorld { _ in }
            world.launcher.show(mode: .applications)
            let results = [
                UninstallItemResult(url: world.appURL, isApp: true, outcome: .moved(to: nil)),
                UninstallItemResult(url: URL(fileURLWithPath: Path.settings), isApp: false, outcome: .moved(to: nil)),
                UninstallItemResult(url: URL(fileURLWithPath: Path.cache), isApp: false, outcome: .notMoved(.permissionDenied)),
            ]
            return UninstallSheetModel(results: results, launcher: world.launcher, dependencies: world.dependencies)
        }
    }
}
