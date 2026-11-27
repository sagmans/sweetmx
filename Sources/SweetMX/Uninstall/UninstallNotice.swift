import Foundation

/// A warning the confirmation sheet shows before an app is removed, or the reason it cannot be.
///
/// Dragging an app to the Trash leaves some products half installed: they run a driver or a
/// firewall that only their own uninstaller can remove. The sheet reads these values so the person
/// learns that before the app is gone, and so removal stops where a half removal would be harmful.
nonisolated enum UninstallNotice: Equatable, Sendable {
    /// A cask app: the command removes it and its leftovers in the way Homebrew expects.
    case homebrew(command: String)
    /// The vendor ships its own removal steps; `page` explains them.
    case vendorUninstaller(vendor: String, page: URL)
    /// Removal must not go ahead. `page` is nil when no vendor page applies.
    case blocked(reason: BlockReason, page: URL?)

    enum BlockReason: Sendable {
        /// A system extension stays active after its app is trashed and cannot be removed afterwards.
        case systemExtension
        /// A firewall or network filter whose removal must go through the product.
        case securitySoftware
    }

    /// The sheet disables removal on this, so a block cannot be clicked through.
    var blocksRemoval: Bool {
        if case .blocked = self {
            return true
        }
        return false
    }

    /// Blocking notices come first so the sheet leads with the reason removal is off, then the
    /// vendor's own steps, then Homebrew.
    static func notices(
        for target: UninstallTarget,
        homebrew: HomebrewReceipt?,
        fileSystem: FileSystemProtocol
    ) -> [UninstallNotice] {
        var blocks: [UninstallNotice] = []
        var vendors: [UninstallNotice] = []
        if mayHoldSystemExtension(target, fileSystem: fileSystem) {
            blocks.append(.blocked(reason: .systemExtension, page: nil))
        }
        for rule in VendorRule.table where rule.matches(target.bundleID) {
            if rule.blocksRemoval {
                blocks.append(.blocked(reason: .securitySoftware, page: rule.page))
            } else {
                vendors.append(.vendorUninstaller(vendor: rule.vendor, page: rule.page))
            }
        }
        let brew = homebrew.map { [UninstallNotice.homebrew(command: homebrewCommand(for: $0))] } ?? []
        return blocks + vendors + brew
    }

    private static let libraryPath = "Contents/Library"
    private static let systemExtensionsPath = "Contents/Library/SystemExtensions"
    /// One entry is enough to know the folder is not empty; the folder is never read deeper.
    private static let systemExtensionsListLimit = 1
    private static let homebrewCommandFormat = "brew uninstall --cask %@"

    /// Takes the receipt, not a string, so only a token that `HomebrewReceipt.find` validated can
    /// reach text a person may copy into a terminal.
    private static func homebrewCommand(for receipt: HomebrewReceipt) -> String {
        String(format: homebrewCommandFormat, receipt.token)
    }

    /// Fails closed: only a folder that is missing or lists empty clears the app. A listing error, a
    /// link or a plain file in the way could hide an extension, and a missing block is the harmful
    /// mistake because the extension cannot be removed once the app is gone.
    private static func mayHoldSystemExtension(_ target: UninstallTarget, fileSystem: FileSystemProtocol) -> Bool {
        let library = target.bundleURL.appendingPathComponent(libraryPath)
        let folder = target.bundleURL.appendingPathComponent(systemExtensionsPath)
        switch kind(of: library, fileSystem) {
        case .missing: return false
        case .directory: break
        default: return true
        }
        switch kind(of: folder, fileSystem) {
        case .missing: return false
        case .directory: break
        default: return true
        }
        guard let entries = try? fileSystem.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [], limit: systemExtensionsListLimit
        ) else { return true }
        return !entries.isEmpty
    }

    /// An unreadable kind is reported as `.other`, which callers treat as a block.
    private static func kind(of url: URL, _ fileSystem: FileSystemProtocol) -> FileItemKind {
        (try? fileSystem.itemKind(at: url)) ?? .other
    }
}

/// One product whose removal needs a vendor page, kept in a single table so adding a vendor is a
/// row, not new logic. Matching is deliberately broad and case-insensitive: vendors ship helper and
/// variant apps under one family of bundle IDs with mixed case, and a notice that matches too much
/// only adds a harmless warning, while one that matches too little lets a half removal through.
/// Rule values are stored lowercased and compared with the lowercased bundle ID.
nonisolated struct VendorRule: Sendable {
    enum Match: Sendable {
        case exact(String)
        case prefix(String)
    }

    let match: Match
    let vendor: String
    let page: URL
    /// True where a half removal is harmful, so the sheet must not offer removal at all.
    let blocksRemoval: Bool

    func matches(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        switch match {
        case let .exact(value): return id == value
        case let .prefix(prefix): return id.hasPrefix(prefix)
        }
    }

    /// Only a page that was read belongs here. Each row says how its ID was verified.
    static let table: [VendorRule] = [
        // Page: https://docs.docker.com/desktop/uninstall/
        // ID: read locally from the installed Docker.app Info.plist (`com.docker.docker`); the
        // trailing dot also covers its helper apps.
        VendorRule(
            match: .prefix("com.docker."), vendor: DesignTokens.Copy.vendorDockerDesktop,
            page: url("https://docs.docker.com/desktop/uninstall/"), blocksRemoval: false
        ),
        // Page: https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/
        // ID: public Homebrew cask definition (karabiner-elements.rb) names
        // `org.pqrs.Karabiner-Elements.Settings`, `org.pqrs.Karabiner-Menu` and similar.
        VendorRule(
            match: .prefix("org.pqrs.karabiner"), vendor: DesignTokens.Copy.vendorKarabinerElements,
            page: url("https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/"), blocksRemoval: false
        ),
        // Page: https://help.obdev.at/littlesnitch6/intro-uninstall
        // ID: public Homebrew cask definition (little-snitch.rb) quits `at.obdev.littlesnitch`; the
        // same cask lists helper IDs such as `at.obdev.LittleSnitchConfiguration`, so matching is
        // case-insensitive.
        VendorRule(
            match: .prefix("at.obdev.littlesnitch"), vendor: DesignTokens.Copy.vendorLittleSnitch,
            page: url("https://help.obdev.at/littlesnitch6/intro-uninstall"), blocksRemoval: true
        ),
    ]

    /// The one place a constant URL is built; a typo fails at once in every test run, not in front
    /// of a person.
    private static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("Invalid vendor page URL: \(text)") }
        return url
    }
}
