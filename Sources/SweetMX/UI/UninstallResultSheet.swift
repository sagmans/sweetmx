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
                    .uninstallButtonStyle(prominent: true)
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

    private var sentence: String {
        reason.map(DesignTokens.Copy.uninstallReason) ?? DesignTokens.Copy.uninstallResultMoved
    }

    /// A missing item has nothing to show, so it gets no Finder button.
    private var canReveal: Bool {
        reason != nil && reason != .missing
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Metrics.tightSpacing) {
            Image(systemName: reason == nil ? DesignTokens.Symbol.uninstallMoved : DesignTokens.Symbol.uninstallNotMoved)
                .foregroundStyle(reason == nil ? DesignTokens.Palette.uninstallMoved : DesignTokens.Palette.error)
                .frame(width: DesignTokens.Metrics.uninstallMarkWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                Text(result.url.lastPathComponent)
                    .font(DesignTokens.Typography.uninstallRowTitle)
                Text(model.displayPath(result.url))
                    .font(DesignTokens.Typography.uninstallRowDetail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(result.url.path)
                Text(sentence)
                    .font(DesignTokens.Typography.uninstallRowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if canReveal {
                Button(DesignTokens.Copy.uninstallShowInFinder) { model.showInFinder(result.url) }
                    .uninstallButtonStyle(prominent: false)
                    .controlSize(.small)
            }
        }
        .padding(DesignTokens.Metrics.uninstallRowPadding)
        .accessibilityElement(children: .combine)
    }
}
