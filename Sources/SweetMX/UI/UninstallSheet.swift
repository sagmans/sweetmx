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
                AnyView(UninstallResultView(model: model))
            } else {
                AnyView(UninstallConfirmationView(model: model))
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
    /// Measured heights of the whole confirmation and of its list, so the list can give up exactly the
    /// room the rest needs and the sheet stays within the launcher panel.
    @State private var contentHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var noticesHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallBlockSpacing) {
            // Erased at each block boundary: the blocks change as a whole, and concrete nested view
            // types multiply the generic code the app ships.
            AnyView(header)
            if let refusal = model.refusal {
                // The header already says the app cannot be removed; the box gives only the reason.
                UninstallNoticeBox(title: nil, message: DesignTokens.Copy.uninstallRefusal(refusal), severity: .blocking)
            }
            if !model.notices.isEmpty {
                UninstallNoticeStack(model: model, maxHeight: noticesLimit)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { noticesHeight = $0 }
            }
            AnyView(content)
            AnyView(footer)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
    }

    /// Height the panel leaves for the blocks inside the padding.
    private var room: CGFloat {
        DesignTokens.Metrics.uninstallSheetMaxHeight - 2 * DesignTokens.Metrics.uninstallSheetPadding
    }

    /// Everything that never gives way (header, choice, footer, gaps), so the two blocks that do can
    /// share what is left.
    private var fixedHeight: CGFloat {
        contentHeight - listHeight - noticesHeight
    }

    /// The list's height limit: what is left of the panel height after everything else, up to the usual
    /// maximum. It never drops below one whole row: a half row says nothing, and the notices give way
    /// first (see `noticesLimit`).
    private var listLimit: CGFloat {
        let left = room - fixedHeight - noticesHeight
        return min(max(left, DesignTokens.Metrics.uninstallListMinHeight), DesignTokens.Metrics.uninstallListMaxHeight)
    }

    /// The notices' height limit: what the panel leaves once the list has its one-row floor. Past it the
    /// notices scroll, so every notice stays reachable and the sheet stays within the launcher.
    private var noticesLimit: CGFloat {
        max(room - fixedHeight - DesignTokens.Metrics.uninstallListMinHeight, DesignTokens.Metrics.uninstallNoticesMinHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallLineSpacing) {
            Text(model.title)
                .font(DesignTokens.Typography.confirmationTitle)
                .accessibilityAddTraits(.isHeader)
            Text(model.appLocation)
                .font(DesignTokens.Typography.uninstallDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.fullPath(URL(fileURLWithPath: model.bundlePath)))
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
            // A mix of ticks selects no segment: neither name would be true.
            Picker(DesignTokens.Copy.uninstallChoiceLabel, selection: Binding<UninstallSheetModel.Choice?>(
                get: { model.choice },
                set: { $0.map(model.setChoice) }
            )) {
                Text(DesignTokens.Copy.uninstallChoiceAppOnly).tag(UninstallSheetModel.Choice?.some(.appOnly))
                Text(DesignTokens.Copy.uninstallChoiceEverything).tag(UninstallSheetModel.Choice?.some(.everything))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(DesignTokens.Copy.uninstallChoiceLabel)
            .accessibilityHint(DesignTokens.Copy.uninstallChoiceHelp)
            .help(DesignTokens.Copy.uninstallChoiceHelp)
            .disabled(!model.canChoose)
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
            Text(DesignTokens.Copy.uninstallNoRelatedItems)
                .font(DesignTokens.Typography.uninstallDetail)
                .foregroundStyle(.secondary)
        } else {
            UninstallRowList(model: model, maxHeight: listLimit)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
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
                .onChange(of: model.listFocusRequests) { listFocused = true }
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
                .launcherButtonStyle()
                .disabled(!model.canCancel)
            if model.isBlocked {
                exitButton
            } else {
                Button(role: .destructive) {
                    model.confirm()
                } label: {
                    Text(model.confirmTitle)
                }
                .launcherButtonStyle(prominent: true)
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
                .launcherButtonStyle(prominent: true)
        } else {
            Button(DesignTokens.Copy.uninstallShowInFinder) {
                model.showInFinder(URL(fileURLWithPath: model.bundlePath))
            }
            .launcherButtonStyle(prominent: true)
        }
    }
}

/// The notices above the list. Scrolls past `maxHeight` so a crowded sheet keeps its list readable
/// instead of cutting a row in half; with room to spare it is as tall as its notices.
private struct UninstallNoticeStack: View {
    let model: UninstallSheetModel
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Metrics.uninstallBlockSpacing) {
                ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                    UninstallNoticeView(notice: notice, model: model)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, maxHeight))
    }
}

/// The related rows in two groups: what can move, then what stays. Scrolls past a fixed height so a
/// long list cannot push the buttons off the launcher.
private struct UninstallRowList: View {
    let model: UninstallSheetModel
    let maxHeight: CGFloat
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
            .frame(height: min(contentHeight, maxHeight))
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
        UninstallRowLayout(
            symbol: markSymbol,
            symbolColor: row.isLocked ? .secondary : .accentColor,
            kind: DesignTokens.Copy.uninstallKind(row.item.kind),
            kindMark: matchMark,
            title: nil,
            path: path,
            fullPath: model.fullPath(row.item.url),
            detail: detail,
            reveal: row.isLocked ? row.item.url : nil,
            model: model
        )
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
        .accessibilityActions {
            // A locked row cannot change, so it offers no action that would do nothing.
            if !row.isLocked {
                Button(DesignTokens.Copy.uninstallToggleAction) { model.toggle(index) }
            }
            Button(DesignTokens.Copy.uninstallShowInFinder) { model.showInFinder(row.item.url) }
        }
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
        row.item.sizeBytes.map(model.sizeText) ?? DesignTokens.Copy.uninstallSizeUnknown
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
    /// The item Show in Finder reveals; nil hides the button.
    let reveal: URL?
    let model: UninstallSheetModel

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
            if let reveal {
                Button(DesignTokens.Copy.uninstallShowInFinder) { model.showInFinder(reveal) }
                    .launcherButtonStyle()
                    .controlSize(.small)
                    .disabled(model.phase == .moving)
            }
        }
        .padding(DesignTokens.Metrics.uninstallRowPadding)
    }
}
