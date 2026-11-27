import Foundation
@testable import SweetMX

/// A scripted Mac with one removable app and the Library items the sheet tests need, shared by the
/// sheet model tests and the sheet snapshots so both describe the same world. Nothing here touches a
/// real app, Trash or home folder.
@MainActor
final class UninstallSheetFixture {
    enum Path {
        static let home = "/Users/testuser"
        static let library = "/Users/testuser/Library"
        static let appFolder = "/Applications"
        static let app = "/Applications/Sample.app"
        static let bundleID = "com.example.sample"
        static let displayName = "Sample"
        static let infoPlist = "/Applications/Sample.app/Contents/Info.plist"
        static let bundleLibrary = "/Applications/Sample.app/Contents/Library"
        static let systemExtensions = "/Applications/Sample.app/Contents/Library/SystemExtensions"
        static let systemExtension = "/Applications/Sample.app/Contents/Library/SystemExtensions/com.example.sample.filter.systemextension"
        static let settings = "/Users/testuser/Library/Preferences/com.example.sample.plist"
        static let cache = "/Users/testuser/Library/Caches/com.example.sample"
        static let nameMatch = "/Users/testuser/Library/Application Support/Sample"
        static let container = "/Users/testuser/Library/Containers/com.example.sample"
        static let homebrewItem = "/Users/testuser/Library/WebKit/com.example.sample.helper"
        static let caskroom = "/opt/homebrew/Caskroom"
        static let caskToken = "sample"
        static let caskVersion = "1.0"
        static let appFileName = "Sample.app"
        static let metadata = ".metadata"
        static let receipt = ".metadata/INSTALL_RECEIPT.json"
        static let homebrewZapPath = "~/Library/WebKit/com.example.sample.helper"
        /// Folders besides Preferences and Caches where the scan finds bundle ID items.
        static let extraBundleIDFolders = ["HTTPStorages", "WebKit", "Logs", "Application Support"]
        static let preferences = "Preferences"
        static let caches = "Caches"
        static let plistExtension = "plist"
        /// Matches the Docker vendor rule, so the sheet shows a vendor notice.
        static let vendorBundleID = "com.docker.sample"
    }

    enum Size {
        static let app: Int64 = 52_400_000
        static let settings: Int64 = 4096
        static let cache: Int64 = 82_000_000
        static let homebrewItem: Int64 = 1_200_000
    }

    private static let plistKey = "CFBundleIdentifier"

    let fileSystem = MockFileSystem()
    let workspace = MockWorkspace()
    let identity = MockCodeIdentity()
    let finder = MockFinderTrash()
    let launcher: LauncherModel
    /// The target's bundle ID; the bundle ID items are named after it.
    let bundleID: String
    var finderHandOffEnabled = false
    /// The app index; the target itself by default, as a loaded index lists it. Nil means no index.
    var installedApps: [ApplicationInfo]? = [ApplicationInfo(name: Path.displayName, bundlePath: Path.app)]
    /// Pinned so sizes read the same on every Mac.
    static let locale = Locale(identifier: "en_US")

    init(bundleID: String = Path.bundleID) {
        self.bundleID = bundleID
        launcher = LauncherModel(
            workspace: workspace,
            pasteboard: MockPasteboard(),
            eventSource: MockEventSource(),
            fileSystem: fileSystem
        )
        fileSystem.writableDirectories.insert(Path.appFolder)
        fileSystem.addFile(at: Path.app, isDirectory: true)
        let info = try? PropertyListSerialization.data(
            fromPropertyList: [Self.plistKey: bundleID], format: .xml, options: 0
        )
        fileSystem.addFile(at: Path.infoPlist, contents: info)
        fileSystem.allocatedSizes[Path.app] = Size.app
        identity.setIdentifier(bundleID, forBundleAt: URL(fileURLWithPath: Path.app))
    }

    var appURL: URL {
        URL(fileURLWithPath: Path.app)
    }

    var dependencies: UninstallDependencies {
        let apps = installedApps
        return UninstallDependencies(
            fileSystem: fileSystem,
            workspace: workspace,
            codeIdentity: identity,
            finder: finder,
            ownBundleID: nil,
            finderHandOffEnabled: finderHandOffEnabled,
            installedApps: { apps },
            locale: Self.locale
        )
    }

    /// A sheet model on the presented launcher, loaded and ready, like the sheet after its scan.
    func loadedModel() async -> UninstallSheetModel {
        if !launcher.isPresented {
            launcher.show(mode: .applications)
        }
        let model = UninstallSheetModel(bundlePath: Path.app, launcher: launcher, dependencies: dependencies)
        model.start()
        await model.loadTask?.value
        return model
    }

    // MARK: - World

    /// Lists an item in its folder too, because the scan finds bundle ID items by listing.
    func put(_ path: String, size: Int64?) {
        fileSystem.addFile(at: path, isDirectory: true)
        let parent = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        fileSystem.directoryContents[parent, default: []].append(URL(fileURLWithPath: path))
        if let size {
            fileSystem.allocatedSizes[path] = size
        }
    }

    /// Settings and a cache: two selectable bundle ID rows.
    func addBundleIDItems() {
        let library = URL(fileURLWithPath: Path.library)
        let settings = library.appendingPathComponent(Path.preferences)
            .appendingPathComponent(bundleID).appendingPathExtension(Path.plistExtension)
        put(settings.path, size: Size.settings)
        put(library.appendingPathComponent(Path.caches).appendingPathComponent(bundleID).path, size: Size.cache)
    }

    /// Every Library folder the scan reads by bundle ID, for a list longer than the sheet can show.
    func addEveryBundleIDItem() {
        addBundleIDItems()
        for folder in Path.extraBundleIDFolders {
            put(Path.library + "/" + folder + "/" + bundleID, size: Size.settings)
        }
    }

    /// A folder named like the app: selectable with the "Matched by name" mark, size unknown.
    func addNameMatch() {
        put(Path.nameMatch, size: nil)
    }

    /// The sandbox container, always locked.
    func addContainer() {
        fileSystem.addFile(at: Path.container, isDirectory: true)
    }

    /// A cask receipt whose cleanup list names a helper folder, which the scan lists as a locked
    /// Homebrew row because its name only extends the bundle ID.
    func addHomebrew() throws {
        let receipt: [String: Any] = [
            "uninstall_artifacts": [["app": [Path.appFileName]], ["zap": [["trash": [Path.homebrewZapPath]]]]],
        ]
        let root = URL(fileURLWithPath: Path.caskroom)
        let token = root.appendingPathComponent(Path.caskToken)
        let version = token.appendingPathComponent(Path.caskVersion)
        let link = version.appendingPathComponent(Path.appFileName)
        fileSystem.directoryContents[root] = [token]
        fileSystem.directoryContents[token] = [token.appendingPathComponent(Path.metadata), version]
        fileSystem.directoryContents[version] = [link]
        fileSystem.fileContents[token.appendingPathComponent(Path.receipt).path] = try JSONSerialization.data(withJSONObject: receipt)
        fileSystem.symbolicLinks.insert(link.path)
        fileSystem.resolvedPaths[link.path] = appURL
        put(Path.homebrewItem, size: Size.homebrewItem)
    }

    /// A bundle with a system extension, which blocks removal.
    func addSystemExtension() {
        fileSystem.itemKinds[Path.bundleLibrary] = .directory
        fileSystem.itemKinds[Path.systemExtensions] = .directory
        fileSystem.directoryContents[URL(fileURLWithPath: Path.systemExtensions)] = [URL(fileURLWithPath: Path.systemExtension)]
    }

    /// The account cannot write the app's folder, so only Finder could move it.
    func makeAppFolderReadOnly() {
        fileSystem.writableDirectories.remove(Path.appFolder)
    }
}
