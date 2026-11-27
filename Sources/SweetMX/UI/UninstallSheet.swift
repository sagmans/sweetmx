import SwiftUI

/// The content of the uninstall sheet: the confirmation while the person decides, the result list
/// after a move that left something behind. One view for both, so the result appears in the same
/// sheet window instead of a second prompt.
///
/// `UninstallPrompt` hosts it; `UninstallSheetModel` owns every decision, and this view only draws it.
struct UninstallSheetView: View {
    let model: UninstallSheetModel

    var body: some View {
        Group {
            if model.showsResults {
                UninstallResultView(model: model)
            } else {
                UninstallConfirmationView(model: model)
            }
        }
        .padding(DesignTokens.Metrics.uninstallSheetPadding)
        .frame(width: DesignTokens.Metrics.uninstallSheetWidth, alignment: .leading)
        // The sheet window follows the content, so it must report its full height, not the window's.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { model.onSizeChange($0) }
    }
}

/// The question: what the app is, what else can move, what stays, and the one destructive button.
private struct UninstallConfirmationView: View {
    let model: UninstallSheetModel
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallBlockSpacing) {
            header
            if let refusal = model.refusal {
                UninstallNoticeBox(
                    title: DesignTokens.Copy.uninstallRefusedTitle(model.displayName),
                    message: DesignTokens.Copy.uninstallRefusal(refusal),
                    severity: .blocking
                )
            }
            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                UninstallNoticeView(notice: notice, model: model)
            }
            content
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
            Text(model.refusal == nil
                ? DesignTokens.Copy.uninstallTitle(model.displayName)
                : DesignTokens.Copy.uninstallRefusedTitle(model.displayName))
                .font(DesignTokens.Typography.confirmationTitle)
                .accessibilityAddTraits(.isHeader)
            Text(model.appLocation)
                .font(DesignTokens.Typography.uninstallDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.bundlePath)
            if model.appIsRunning, !model.isBlocked {
                Text(DesignTokens.Copy.uninstallAppRunning(model.displayName))
                    .font(DesignTokens.Typography.uninstallDetail)
                    .foregroundStyle(DesignTokens.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .scanning:
            HStack(spacing: DesignTokens.Metrics.tightSpacing) {
                ProgressView().controlSize(.small)
                Text(DesignTokens.Copy.uninstallScanning)
                    .font(DesignTokens.Typography.uninstallDetail)
                    .foregroundStyle(.secondary)
            }
        case .ready, .moving, .finished:
            if !model.isBlocked {
                choice
                list
            }
        }
    }

    @ViewBuilder
    private var choice: some View {
        if model.rows.contains(where: { !$0.isLocked }) {
            Picker(DesignTokens.Copy.uninstallChoiceLabel, selection: Binding(
                get: { model.choice },
                set: { model.setChoice($0) }
            )) {
                Text(DesignTokens.Copy.uninstallChoiceAppOnly).tag(UninstallSheetModel.Choice.appOnly)
                Text(DesignTokens.Copy.uninstallChoiceEverything).tag(UninstallSheetModel.Choice.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(DesignTokens.Copy.uninstallChoiceLabel)
            .disabled(model.phase != .ready)
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
            Text(DesignTokens.Copy.uninstallNoRelatedItems)
                .font(DesignTokens.Typography.uninstallDetail)
                .foregroundStyle(.secondary)
        } else {
            UninstallRowList(model: model)
                .focusable(model.phase == .ready)
                .focused($listFocused)
                .onKeyPress(.space) {
                    model.toggleFocusedRow()
                    return .handled
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(DesignTokens.Copy.uninstallRelatedListLabel)
                .accessibilityHint(DesignTokens.Copy.uninstallRelatedListHelp)
                .onAppear { listFocused = true }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
            if model.phase == .moving {
                HStack(spacing: DesignTokens.Metrics.tightSpacing) {
                    ProgressView().controlSize(.small)
                    Text(DesignTokens.Copy.uninstallMoving)
                }
                .font(DesignTokens.Typography.uninstallDetail)
            } else if !model.isBlocked {
                Text(DesignTokens.Copy.uninstallTrashFooter)
                if model.hasLockedRows {
                    Text(DesignTokens.Copy.uninstallSomeItemsStay)
                }
            }
            buttons
                .padding(.top, DesignTokens.Metrics.confirmationButtonTopSpacing)
            if let note = model.administratorNote {
                Text(note)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(DesignTokens.Typography.uninstallDetail)
        .foregroundStyle(.secondary)
    }

    private var buttons: some View {
        HStack(spacing: DesignTokens.Metrics.inlineSpacing) {
            Spacer(minLength: 0)
            Button(DesignTokens.Copy.cancel) { model.close() }
                .uninstallButtonStyle(prominent: false)
                .disabled(!model.canCancel)
            if model.isBlocked {
                exitButton
            } else {
                Button(role: .destructive) {
                    model.confirm()
                } label: {
                    Text(model.confirmTitle)
                }
                .uninstallButtonStyle(prominent: true)
                .tint(DesignTokens.Palette.destructiveAction)
                .disabled(!model.canConfirm)
                .help(DesignTokens.Copy.uninstallConfirmHelp)
            }
        }
        .controlSize(.large)
        .foregroundStyle(.primary)
    }

    /// A blocked or refused app gets a way to finish elsewhere: the vendor page when a blocking notice
    /// names one, Finder otherwise.
    @ViewBuilder
    private var exitButton: some View {
        if let page = model.blockingPage {
            Button(DesignTokens.Copy.uninstallOpenInstructions) { model.openInstructions(page) }
                .uninstallButtonStyle(prominent: true)
        } else {
            Button(DesignTokens.Copy.uninstallShowInFinder) {
                model.showInFinder(URL(fileURLWithPath: model.bundlePath))
            }
            .uninstallButtonStyle(prominent: true)
        }
    }
}

/// The related rows in two groups: what can move, then what stays. Scrolls past a fixed height so a
/// long list cannot push the buttons off the launcher.
private struct UninstallRowList: View {
    let model: UninstallSheetModel
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallRowSpacing) {
                    section(DesignTokens.Copy.uninstallSelectableSection, locked: false)
                    section(DesignTokens.Copy.uninstallLockedSection, locked: true)
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, DesignTokens.Metrics.uninstallListMaxHeight))
            .onChange(of: model.focusedRow) { _, row in
                if let row {
                    proxy.scrollTo(model.rows[row].id)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, locked: Bool) -> some View {
        let indices = model.rows.indices.filter { model.rows[$0].isLocked == locked }
        if !indices.isEmpty {
            Text(title)
                .font(DesignTokens.Typography.uninstallSection)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(indices, id: \.self) { index in
                UninstallRowView(model: model, index: index)
                    .id(model.rows[index].id)
            }
        }
    }
}

/// One related item: kind, path, size, and what removing it does, or why it is locked.
private struct UninstallRowView: View {
    let model: UninstallSheetModel
    let index: Int

    private var row: UninstallSheetModel.Row {
        model.rows[index]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Metrics.tightSpacing) {
            Image(systemName: markSymbol)
                .foregroundStyle(row.isLocked ? Color.secondary : Color.accentColor)
                .frame(width: DesignTokens.Metrics.uninstallMarkWidth)
            // A kind column, like the spec's sheet, so paths line up and each row takes two lines.
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                Text(DesignTokens.Copy.uninstallKind(row.item.kind))
                    .font(DesignTokens.Typography.uninstallRowTitle)
                if let mark = matchMark {
                    Text(mark)
                        .font(DesignTokens.Typography.uninstallRowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: DesignTokens.Metrics.uninstallKindColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
                Text(path)
                    .font(DesignTokens.Typography.uninstallPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.item.url.path)
                Text(detail)
                    .font(DesignTokens.Typography.uninstallRowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if row.isLocked {
                Button(DesignTokens.Copy.uninstallShowInFinder) { model.showInFinder(row.item.url) }
                    .uninstallButtonStyle(prominent: false)
                    .controlSize(.small)
                    .disabled(model.phase != .ready)
            }
        }
        .padding(DesignTokens.Metrics.uninstallRowPadding)
        .background(
            DesignTokens.Palette.appTint.opacity(model.focusedRow == index ? DesignTokens.Palette.uninstallFocusOpacity : 0),
            in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.uninstallCornerRadius)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(index) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenState)
        .accessibilityAddTraits(row.isLocked ? [] : .isToggle)
        .accessibilityAction(named: DesignTokens.Copy.uninstallToggleAction) { model.toggle(index) }
        .accessibilityAction(named: DesignTokens.Copy.uninstallShowInFinder) { model.showInFinder(row.item.url) }
    }

    private var markSymbol: String {
        if row.isLocked {
            return DesignTokens.Symbol.uninstallLocked
        }
        return row.isTicked ? DesignTokens.Symbol.uninstallChecked : DesignTokens.Symbol.uninstallUnchecked
    }

    /// Only selectable rows carry the mark: on a locked row the lock reason already says how sure the scan is.
    private var matchMark: String? {
        guard !row.isLocked else { return nil }
        switch row.item.match {
        case .bundleID: return nil
        case .name: return DesignTokens.Copy.uninstallMatchedByName
        case .homebrew: return DesignTokens.Copy.uninstallListedByHomebrew
        }
    }

    private var path: String {
        model.displayPath(row.item.url)
    }

    private var size: String {
        row.item.sizeBytes.map(DesignTokens.uninstallSize) ?? DesignTokens.Copy.uninstallSizeUnknown
    }

    private var detail: String {
        if let lock = row.item.lock {
            return DesignTokens.Copy.uninstallLockReason(lock)
        }
        return [size, DesignTokens.Copy.uninstallEffect(row.item.kind)].joined(separator: DesignTokens.Copy.uninstallDetailSeparator)
    }

    private var spokenLabel: String {
        [DesignTokens.Copy.uninstallKind(row.item.kind), path, size]
            .joined(separator: DesignTokens.Copy.labelSeparator)
    }

    private var spokenState: String {
        if let lock = row.item.lock {
            return DesignTokens.Copy.uninstallRowLocked(DesignTokens.Copy.uninstallLockReason(lock))
        }
        return row.isTicked ? DesignTokens.Copy.uninstallRowSelected : DesignTokens.Copy.uninstallRowNotSelected
    }
}

/// One notice from the scan, with the Homebrew command to copy or the vendor's page.
private struct UninstallNoticeView: View {
    let notice: UninstallNotice
    let model: UninstallSheetModel

    var body: some View {
        UninstallNoticeBox(
            title: DesignTokens.Copy.uninstallNoticeTitle(notice),
            message: DesignTokens.Copy.uninstallNoticeBody(notice),
            severity: severity
        ) {
            switch notice {
            case let .homebrew(command):
                Text(command)
                    .font(DesignTokens.Typography.uninstallCommand)
                    .textSelection(.enabled)
            case let .vendorUninstaller(_, page):
                Button(DesignTokens.Copy.uninstallOpenInstructions) { model.openInstructions(page) }
                    .buttonStyle(.link)
                    .disabled(model.phase != .ready)
            case .blocked:
                EmptyView()
            }
        }
    }

    private var severity: UninstallNoticeSeverity {
        switch notice {
        case .homebrew: .information
        case .vendorUninstaller: .warning
        case .blocked: .blocking
        }
    }
}

/// How strongly a notice speaks: a fact, a caution, or the reason nothing can move.
enum UninstallNoticeSeverity {
    case information, warning, blocking
}

/// The tinted box every notice and refusal uses, so a block always looks like a block.
struct UninstallNoticeBox<Extra: View>: View {
    let title: String
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
                Text(title).font(DesignTokens.Typography.uninstallRowTitle)
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
    init(title: String, message: String, severity: UninstallNoticeSeverity) {
        self.init(title: title, message: message, severity: severity) { EmptyView() }
    }
}

/// Glass buttons like the clipboard prompt, swapped for plain bordered ones in snapshot mode, where
/// glass would sample whatever sits behind the test window.
private struct UninstallButtonStyle: ViewModifier {
    let prominent: Bool
    @Environment(\.launcherSnapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        switch (prominent, snapshotMode) {
        case (true, false): content.buttonStyle(.glassProminent)
        case (false, false): content.buttonStyle(.glass)
        case (true, true): content.buttonStyle(.borderedProminent)
        case (false, true): content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// The button style of the uninstall sheets; see `UninstallButtonStyle`.
    func uninstallButtonStyle(prominent: Bool) -> some View {
        modifier(UninstallButtonStyle(prominent: prominent))
    }
}
