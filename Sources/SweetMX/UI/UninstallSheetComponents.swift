import SwiftUI

// The building blocks the confirmation and result sheets share. They take plain values, never the
// sheet model, so each one draws the same way for every state that fills it.

/// How strongly a notice speaks: a fact, a caution, or the reason nothing can move.
enum UninstallNoticeSeverity {
    case information, warning, blocking
}

/// The tinted box every notice and refusal uses, so a block always looks like a block.
struct UninstallNoticeBox<Extra: View>: View {
    /// Nil when the sheet's own title already names the problem.
    let title: String?
    let message: String
    let severity: UninstallNoticeSeverity
    @ViewBuilder var extra: () -> Extra

    private var color: Color {
        switch severity {
        case .information: DesignTokens.Palette.uninstallInformation
        case .warning: DesignTokens.Palette.warning
        case .blocking: DesignTokens.Palette.error
        }
    }

    private var symbol: String {
        switch severity {
        case .information: DesignTokens.Symbol.info
        case .warning: DesignTokens.Symbol.warning
        case .blocking: DesignTokens.Symbol.uninstallBlocked
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Metrics.tightSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                if let title {
                    Text(title).font(DesignTokens.Typography.uninstallRowTitle)
                }
                Text(message)
                    .font(DesignTokens.Typography.uninstallDetail)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Metrics.uninstallNoticePadding)
        .background(
            color.opacity(DesignTokens.Palette.uninstallNoticeOpacity),
            in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.uninstallCornerRadius)
        )
        .accessibilityElement(children: .combine)
    }
}

extension UninstallNoticeBox where Extra == EmptyView {
    /// A notice with nothing below its message, such as a refusal.
    init(title: String?, message: String, severity: UninstallNoticeSeverity) {
        self.init(title: title, message: message, severity: severity) { EmptyView() }
    }
}

/// The one row layout of both sheets: a mark, an optional kind column, the lines, and Show in Finder
/// for an item that stays. Shared so the two lists read alike and the app carries one row view.
struct UninstallRowLayout: View {
    let symbol: String
    let symbolColor: Color
    /// The kind column of a related row; nil in the result list, which names the item instead.
    let kind: String?
    let kindMark: String?
    /// A bold name above the path; nil when the kind column already names the row.
    let title: String?
    let path: String
    /// Shown as help, because the visible path may be truncated in the middle.
    let fullPath: String
    let detail: String
    /// What Show in Finder does; nil hides the button. A closure, not the sheet model, so the layout
    /// stays a plain view that both sheets fill from their own state.
    let onReveal: (() -> Void)?
    /// True while a move runs, so Finder is never asked to show an item that is moving.
    let revealDisabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Metrics.tightSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .frame(width: DesignTokens.Metrics.uninstallMarkWidth)
                .accessibilityHidden(true)
            if let kind {
                // A kind column, like the spec's sheet, so paths line up and each row takes two lines.
                VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                    Text(kind)
                        .font(DesignTokens.Typography.uninstallRowTitle)
                    if let kindMark {
                        Text(kindMark)
                            .font(DesignTokens.Typography.uninstallRowDetail)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: DesignTokens.Metrics.uninstallKindColumnWidth, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                if let title {
                    Text(title)
                        .font(DesignTokens.Typography.uninstallRowTitle)
                }
                Text(path)
                    .font(DesignTokens.Typography.uninstallPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fullPath)
                Text(detail)
                    .font(DesignTokens.Typography.uninstallRowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onReveal {
                Button(DesignTokens.Copy.uninstallShowInFinder, action: onReveal)
                    .launcherButtonStyle()
                    .controlSize(.small)
                    .disabled(revealDisabled)
            }
        }
        .padding(DesignTokens.Metrics.uninstallRowPadding)
    }
}
