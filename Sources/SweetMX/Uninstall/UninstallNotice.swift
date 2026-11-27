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
        if hasSystemExtension(target, fileSystem: fileSystem) {
            blocks.append(.blocked(reason: .systemExtension, page: nil))
        }
        for rule in VendorRule.table where rule.matches(target.bundleID) {
            if rule.blocksRemoval {
                blocks.append(.blocked(reason: .securitySoftware, page: rule.page))
            } else {
                vendors.append(.vendorUninstaller(vendor: rule.vendor, page: rule.page))
            }
        }
        let brew = homebrew.map { [UninstallNotice.homebrew(command: homebrewCommand(token: $0.token))] } ?? []
        return blocks + vendors + brew
    }

    private static let systemExtensionsPath = "Contents/Library/SystemExtensions"
    /// One entry is enough to know the folder is not empty; the folder is never read deeper.
    private static let systemExtensionsListLimit = 1
    /// The token comes from a validated receipt, so it cannot carry shell syntax into the text a
    /// person may copy.
    private static let homebrewCommandFormat = "brew uninstall --cask %@"

    private static func homebrewCommand(token: String) -> String {
        String(format: homebrewCommandFormat, token)
    }

    private static func hasSystemExtension(_ target: UninstallTarget, fileSystem: FileSystemProtocol) -> Bool {
        let folder = target.bundleURL.appendingPathComponent(systemExtensionsPath)
        let entries = try? fileSystem.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [], limit: systemExtensionsListLimit
        )
        return !(entries ?? []).isEmpty
    }
}

/// One product whose removal needs a vendor page, kept in a single table so adding a vendor is a
/// row, not new logic. Matching is on the target's bundle ID, case-sensitive, because a bundle ID
/// is an exact name and a looser match could warn on, or block, an unrelated app.
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
        switch match {
        case let .exact(id): bundleID == id
        case let .prefix(prefix): bundleID.hasPrefix(prefix)
        }
    }

    /// Only a page that was read belongs here; verified against each vendor's own page and the
    /// public Homebrew cask definition.
    static let table: [VendorRule] = [
        // https://docs.docker.com/desktop/uninstall/
        VendorRule(
            match: .exact("com.docker.docker"), vendor: "Docker Desktop",
            page: url("https://docs.docker.com/desktop/uninstall/"), blocksRemoval: false
        ),
        // https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/
        VendorRule(
            match: .prefix("org.pqrs.Karabiner"), vendor: "Karabiner-Elements",
            page: url("https://karabiner-elements.pqrs.org/docs/manual/operation/uninstall/"), blocksRemoval: false
        ),
        // https://help.obdev.at/littlesnitch6/intro-uninstall
        VendorRule(
            match: .prefix("at.obdev.littlesnitch"), vendor: "Little Snitch",
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
