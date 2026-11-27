import SwiftUI

/// What happened to each item after a move that left something behind, so the person knows exactly
/// what is in Trash, what stayed and why. It replaces the confirmation in the same sheet window, and it
/// is also what the launcher shows on its next opening when the move ended while it was closed.
struct UninstallResultView: View {
    let model: UninstallSheetModel
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallBlockSpacing) {
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                Text(DesignTokens.Copy.uninstallResultTitle)
                    .font(DesignTokens.Typography.confirmationTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(DesignTokens.Copy.uninstallResultExplanation)
                    .font(DesignTokens.Typography.uninstallDetail)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallRowSpacing) {
                    ForEach(Array((model.results ?? []).enumerated()), id: \.offset) { _, result in
                        UninstallResultRow(result: result, model: model)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, DesignTokens.Metrics.uninstallResultListMaxHeight))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(DesignTokens.Copy.uninstallResultListLabel)
            HStack {
                Spacer(minLength: 0)
                // The only button and the default one: Return closes, because nothing is left to decide.
                Button(DesignTokens.Copy.uninstallDone) { model.close() }
                    .launcherButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }
}

/// One item of the result: name, path, outcome sentence, and Finder for an item that is still there.
private struct UninstallResultRow: View {
    let result: UninstallItemResult
    let model: UninstallSheetModel

    private var reason: UninstallItemResult.Reason? {
        if case let .notMoved(reason) = result.outcome {
            return reason
        }
        return nil
    }

    /// A missing item has nothing to show, so it gets no Finder button.
    private var canReveal: Bool {
        reason != nil && reason != .missing
    }

    var body: some View {
        UninstallRowLayout(
            symbol: reason == nil ? DesignTokens.Symbol.uninstallMoved : DesignTokens.Symbol.uninstallNotMoved,
            symbolColor: reason == nil ? DesignTokens.Palette.uninstallMoved : DesignTokens.Palette.error,
            kind: nil,
            kindMark: nil,
            title: model.itemName(result.url),
            path: model.displayPath(result.url),
            fullPath: model.fullPath(result.url),
            detail: model.sentence(for: result),
            onReveal: canReveal ? { model.showInFinder(result.url) } : nil,
            revealDisabled: model.phase == .moving
        )
        .accessibilityElement(children: .combine)
    }
}
