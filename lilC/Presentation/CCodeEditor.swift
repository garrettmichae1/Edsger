import SwiftUI
import UIKit
@preconcurrency import Runestone
import TreeSitterCRunestone
import TreeSitterPythonRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterLuaRunestone

/// Keeps the app's editor contract; Runestone owns text layout and incremental parsing.
struct CCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var fileID: String
    var language: ProgrammingLanguage = .c
    var isFocused: Bool
    var jump: CaretJump?
    var findVisible: Bool
    var findQuery: String
    var findIndex: Int
    var findEpoch: Int
    var formatEpoch: Int = 0
    var overlayHeight: CGFloat
    var syntaxColoring: Bool
    var diagnostic: EditorRuntimeDiagnostic? = nil
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> Runestone.TextView {
        let view = Runestone.TextView(frame: .zero)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.showLineNumbers = true
        view.isLineWrappingEnabled = true
        view.indentStrategy = .space(length: 4)
        view.characterPairs = [] // Preserve literal typing and our existing symbol toolbar.
        let accessory = CSymbolAccessoryView(language: language)
        accessory.coordinator = context.coordinator
        view.inputAccessoryView = accessory
        context.coordinator.textView = view
        context.coordinator.accessory = accessory
        context.coordinator.loadFile(in: view)
        view.editorDelegate = context.coordinator
        view.accessibilityIdentifier = "code-editor"
        view.accessibilityLabel = "Code editor"
        applyChrome(view, coordinator: context.coordinator)
        context.coordinator.updateHighlights()
        return view
    }

    func updateUIView(_ view: Runestone.TextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.textView = view
        if coordinator.fileID != fileID {
            coordinator.savePosition(in: view)
            coordinator.loadFile(in: view)
        } else {
            coordinator.applyExternalTextIfNeeded()
            if coordinator.language != language || coordinator.syntaxWasEnabled != syntaxColoring {
                coordinator.language = language
                coordinator.syntaxWasEnabled = syntaxColoring
                view.setLanguageMode(syntaxColoring
                    ? TreeSitterLanguageMode(language: Self.parser(for: language))
                    : PlainTextLanguageMode())
            }
        }
        applyChrome(view, coordinator: coordinator)
        coordinator.updateHighlights()

        if let jump, coordinator.appliedJumpID != jump.id, jump.fileID == nil || jump.fileID == fileID {
            coordinator.appliedJumpID = jump.id
            if let range = EditorTextCoordinates.selection(in: view.text, jump: jump) {
                view.selectedRange = range
                view.scrollRangeToVisible(range)
                if !view.isEditing { view.becomeFirstResponder() }
            }
        }
        if findVisible, coordinator.appliedFindEpoch != findEpoch {
            coordinator.appliedFindEpoch = findEpoch
            let matches = EditorSearch.nsMatches(in: view.text, query: findQuery)
            if matches.indices.contains(findIndex) {
                view.selectedRange = matches[findIndex]
                view.scrollRangeToVisible(matches[findIndex])
            }
        }
        if coordinator.appliedFormatEpoch != formatEpoch {
            coordinator.appliedFormatEpoch = formatEpoch
            if formatEpoch > 0 {
                let expectedFileID = fileID
                DispatchQueue.main.async { [weak coordinator] in
                    guard coordinator?.fileID == expectedFileID else { return }
                    coordinator?.formatBuffer()
                }
            }
        }
        // Runestone's inner text input is the responder; TextView.isFirstResponder
        // is not the editing-state flag. Never chase a lagging SwiftUI focus value.
        if CCodeEditorKeyboardPolicy.shouldBecomeFirstResponder(
            swiftUIWantsFocus: isFocused, textViewIsFirstResponder: view.isEditing
        ) {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, view.window != nil, coordinator?.parent.isFocused == true, !view.isEditing else { return }
                view.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ view: Runestone.TextView, coordinator: Coordinator) {
        view.editorDelegate = nil
        coordinator.textView = nil
        coordinator.accessory?.coordinator = nil
    }

    private func applyChrome(_ view: Runestone.TextView, coordinator: Coordinator) {
        let way = AppearanceStore.shared.colorWay
        if coordinator.colorWay != way {
            coordinator.colorWay = way
            view.theme = EdsgerEditorTheme(way: way)
        }
        let accent = UIColor(AppPalette.green)
        view.backgroundColor = UIColor(AppPalette.editor)
        view.tintColor = accent
        view.insertionPointColor = accent
        view.selectionBarColor = accent
        view.selectionHighlightColor = accent.withAlphaComponent(0.2)
        view.keyboardAppearance = way == .dark ? .dark : .default
        view.textContainerInset = UIEdgeInsets(top: 8 + overlayHeight, left: 10, bottom: 8, right: 10)
        coordinator.accessory?.applyPalette()
    }

    fileprivate static func parser(for language: ProgrammingLanguage) -> TreeSitterLanguage {
        switch language {
        case .c: .c
        case .python: .python
        case .javascript: .javaScript
        case .lua: .lua
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency Runestone.TextViewDelegate {
        var parent: CCodeEditor
        weak var textView: Runestone.TextView?
        weak var accessory: CSymbolAccessoryView?
        var fileID = ""
        var language: ProgrammingLanguage = .c
        var syntaxWasEnabled = false
        var colorWay: AppColorWay?
        var appliedJumpID: UUID?
        var appliedFindEpoch = -1
        var appliedFormatEpoch = 0
        var lastPublishedText: String
        private var isApplyingText = false
        private var positions: [String: (selection: NSRange, offset: CGPoint)] = [:]

        init(parent: CCodeEditor) {
            self.parent = parent
            self.lastPublishedText = parent.text
        }

        func savePosition(in view: Runestone.TextView) {
            guard !fileID.isEmpty else { return }
            if positions.count >= 100 { positions.removeAll(keepingCapacity: true) }
            positions[fileID] = (view.selectedRange, view.contentOffset)
        }

        func loadFile(in view: Runestone.TextView) {
            isApplyingText = true
            defer { isApplyingText = false }
            if language != parent.language {
                let newAccessory = CSymbolAccessoryView(language: parent.language)
                newAccessory.coordinator = self
                view.inputAccessoryView = newAccessory
                accessory = newAccessory
                view.reloadInputViews()
            }
            fileID = parent.fileID
            language = parent.language
            syntaxWasEnabled = parent.syntaxColoring
            colorWay = AppearanceStore.shared.colorWay
            let theme = EdsgerEditorTheme(way: AppearanceStore.shared.colorWay)
            let state = parent.syntaxColoring
                ? TextViewState(text: parent.text, theme: theme, language: CCodeEditor.parser(for: language))
                : TextViewState(text: parent.text, theme: theme)
            // A document switch must not allow undo to insert another file's text.
            view.setState(state)
            if let lineEndings = state.detectedLineEndings { view.lineEndings = lineEndings }
            else { view.lineEndings = .lf }
            lastPublishedText = parent.text
            let position = positions[fileID]
            view.selectedRange = EditorTextCoordinates.clampedSelection(position?.selection ?? NSRange(location: 0, length: 0), in: view.text)
            view.setContentOffset(clampedOffset(position?.offset ?? .zero, in: view), animated: false)
            appliedFindEpoch = -1
            appliedFormatEpoch = parent.formatEpoch
            view.accessibilityValue = view.text
        }

        func applyExternalTextIfNeeded() {
            guard let view = textView,
                  CCodeEditorKeyboardPolicy.shouldApplyBoundText(
                    fileChanged: false, isFirstResponder: view.isEditing,
                    viewText: view.text, boundText: parent.text,
                    lastPublishedText: lastPublishedText, hasMarkedText: view.markedTextRange != nil
                  ) else { return }
            let selection = view.selectedRange
            let offset = view.contentOffset
            replaceBuffer(with: parent.text, selection: selection, publish: false)
            view.setContentOffset(clampedOffset(offset, in: view), animated: false)
        }

        private func clampedOffset(_ offset: CGPoint, in view: Runestone.TextView) -> CGPoint {
            let inset = view.adjustedContentInset
            let minX = -inset.left
            let minY = -inset.top
            let maxX = max(minX, view.contentSize.width - view.bounds.width + inset.right)
            let maxY = max(minY, view.contentSize.height - view.bounds.height + inset.bottom)
            return CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY))
        }

        func textView(_ view: Runestone.TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !isApplyingText, parent.language != .c,
                  (text == "\n" || text == "\r\n" || text == "\r"), range.length == 0,
                  view.markedTextRange == nil else { return true }
            let before = (view.text as NSString).substring(to: range.location).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let insertion = ScriptSyntax.newlineIndent(before: before, language: parent.language)
            let normalized = insertion.replacingOccurrences(of: "\n", with: text)
            isApplyingText = true
            view.replace(range, withText: normalized)
            isApplyingText = false
            view.selectedRange = NSRange(location: range.location + (normalized as NSString).length, length: 0)
            publishText()
            return false
        }

        func textViewDidChange(_ view: Runestone.TextView) {
            guard !isApplyingText else { return }
            publishText()
        }

        func textViewDidBeginEditing(_ view: Runestone.TextView) { parent.onBeginEditing() }
        func textViewDidEndEditing(_ view: Runestone.TextView) { parent.onEndEditing() }

        private func publishText() {
            guard let view = textView else { return }
            lastPublishedText = view.text
            if parent.text != view.text { parent.text = view.text }
            view.accessibilityValue = view.text
            updateHighlights()
        }

        func updateHighlights() {
            guard let view = textView else { return }
            var ranges: [HighlightedRange] = []
            // Runtime markers never use Tree-sitter ERROR nodes or a desktop linter.
            if view.text == parent.text, let diagnostic = parent.diagnostic, let range = diagnostic.range(in: view.text) {
                ranges.append(HighlightedRange(id: "runtime-error", range: range, color: .systemRed.withAlphaComponent(0.14), cornerRadius: 3))
            }
            if parent.findVisible {
                let accent = UIColor(AppPalette.green)
                for (index, range) in EditorSearch.nsMatches(in: view.text, query: parent.findQuery).enumerated() {
                    ranges.append(HighlightedRange(id: "find-\(index)", range: range, color: accent.withAlphaComponent(index == parent.findIndex ? 0.28 : 0.14), cornerRadius: 2))
                }
            }
            if view.highlightedRanges != ranges { view.highlightedRanges = ranges }
        }

        func hideKeyboard() { textView?.resignFirstResponder() }

        func formatBuffer() {
            guard parent.language == .c, let view = textView, view.markedTextRange == nil else { return }
            let output = CIndentFormatter.formatKeepingCaret(view.text, caretUTF16: view.selectedRange.location)
            guard output.text != view.text else { return }
            replaceBuffer(with: output.text, selection: NSRange(location: output.caretUTF16, length: 0))
        }

        func insertSymbol(_ value: String) {
            textView?.insertText(value)
            publishText()
        }

        func indentSelection(outdent: Bool) {
            guard let view = textView, view.markedTextRange == nil else { return }
            let edit = EditorIndentation.apply(to: view.text, selection: view.selectedRange, outdent: outdent)
            guard edit.text != view.text else { return }
            replaceBuffer(with: edit.text, selection: edit.selection)
        }

        private func replaceBuffer(with text: String, selection: NSRange, publish: Bool = true) {
            guard let view = textView else { return }
            isApplyingText = true
            // Bulk changes are one undoable state transition. Runestone.replace
            // normalizes pasted line endings; state preserves external source bytes
            // exactly, including mixed endings and AI edits, without losing history.
            let state = parent.syntaxColoring
                ? TextViewState(text: text, theme: view.theme, language: CCodeEditor.parser(for: parent.language))
                : TextViewState(text: text, theme: view.theme)
            view.setState(state, addUndoAction: true)
            if let endings = state.detectedLineEndings { view.lineEndings = endings }
            view.selectedRange = EditorTextCoordinates.clampedSelection(selection, in: view.text)
            isApplyingText = false
            lastPublishedText = view.text
            if publish { publishText() }
            else { view.accessibilityValue = view.text }
        }
    }
}

@MainActor
private final class EdsgerEditorTheme: @preconcurrency Runestone.Theme {
    let way: AppColorWay
    let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    let lineNumberFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let textColor: UIColor
    let gutterBackgroundColor: UIColor
    let gutterHairlineColor: UIColor
    let lineNumberColor: UIColor
    let selectedLineBackgroundColor: UIColor
    let selectedLinesLineNumberColor: UIColor
    let selectedLinesGutterBackgroundColor: UIColor
    let invisibleCharactersColor: UIColor
    let pageGuideHairlineColor: UIColor
    let pageGuideBackgroundColor: UIColor = .clear
    let markedTextBackgroundColor: UIColor

    init(way: AppColorWay) {
        self.way = way
        let palette = way.palette
        textColor = UIColor(palette.foreground)
        gutterBackgroundColor = UIColor(palette.editor)
        gutterHairlineColor = UIColor(palette.line)
        lineNumberColor = UIColor(palette.silver)
        selectedLineBackgroundColor = UIColor(palette.accent).withAlphaComponent(0.035)
        selectedLinesLineNumberColor = textColor
        selectedLinesGutterBackgroundColor = gutterBackgroundColor
        invisibleCharactersColor = lineNumberColor
        pageGuideHairlineColor = gutterHairlineColor
        markedTextBackgroundColor = UIColor(palette.accent).withAlphaComponent(0.12)
    }

    func textColor(for highlightName: String) -> UIColor? {
        let name = highlightName.lowercased()
        let kind: CSyntaxKind?
        if name.hasPrefix("comment") { kind = .comment }
        else if name.hasPrefix("string") || name.hasPrefix("character") { kind = .string }
        else if name.hasPrefix("number") || name.hasPrefix("float") || name.hasPrefix("constant.numeric") { kind = .number }
        else if name.hasPrefix("type") { kind = .type }
        else if name.hasPrefix("keyword") || name.hasPrefix("conditional") || name.hasPrefix("repeat") || name.hasPrefix("boolean") { kind = .control }
        else if name.hasPrefix("preproc") || name.hasPrefix("include") { kind = .preprocessor }
        else if name.hasPrefix("operator") { kind = .op }
        else { kind = nil }
        return kind.map { CSyntaxPalette.color($0, way: way) }
    }
}

final class CSymbolAccessoryView: UIInputView {
    weak var coordinator: CCodeEditor.Coordinator?
    private let stack = UIStackView()
    private var symbolButtons: [UIButton] = []
    private var indentButton: UIButton?
    private var outdentButton: UIButton?
    private var formatButton: UIButton?
    private var dismissButton: UIButton?

    var controlAccessibilityLabels: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? UIButton)?.accessibilityLabel }
    }

    init(language: ProgrammingLanguage = .c) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 40), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        for symbol in (language == .python ? [":", "_", "(", ")", "[", "]", "#"] : ["{", "}", "(", ")", ";", "*", "&"]) {
            let button = makeButton(title: symbol, label: symbol)
            button.addAction(UIAction { [weak self] _ in
                self?.coordinator?.insertSymbol(symbol)
            }, for: .touchUpInside)
            symbolButtons.append(button)
            stack.addArrangedSubview(button)
        }

        let outdent = makeButton(systemName: "decrease.indent", label: "Outdent")
        outdent.addAction(UIAction { [weak self] _ in
            self?.coordinator?.indentSelection(outdent: true)
        }, for: .touchUpInside)
        outdentButton = outdent
        stack.addArrangedSubview(outdent)

        let indent = makeButton(systemName: "increase.indent", label: "Indent")
        indent.addAction(UIAction { [weak self] _ in
            self?.coordinator?.indentSelection(outdent: false)
        }, for: .touchUpInside)
        indentButton = indent
        stack.addArrangedSubview(indent)

        let format = makeButton(title: "FMT", label: "Format code")
        format.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        format.addAction(UIAction { [weak self] _ in
            self?.coordinator?.formatBuffer()
        }, for: .touchUpInside)
        formatButton = format
        if language == .c { stack.addArrangedSubview(format) }

        let dismiss = makeButton(systemName: "keyboard.chevron.compact.down", label: "Hide keyboard")
        dismiss.addAction(UIAction { [weak self] _ in
            self?.coordinator?.hideKeyboard()
        }, for: .touchUpInside)
        dismissButton = dismiss
        stack.addArrangedSubview(dismiss)

        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 40)
    }

    func applyPalette() {
        let ink = UIColor(AppPalette.foreground)
        let accent = UIColor(AppPalette.green)
        for button in symbolButtons {
            button.tintColor = ink
            button.setTitleColor(ink, for: .normal)
        }
        indentButton?.tintColor = accent
        outdentButton?.tintColor = accent
        formatButton?.tintColor = accent
        formatButton?.setTitleColor(accent, for: .normal)
        dismissButton?.tintColor = UIColor(AppPalette.silver)
    }

    private func makeButton(title: String? = nil, systemName: String? = nil, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = label
        if let title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        }
        if let systemName {
            let image = UIImage(systemName: systemName)
            button.setImage(image, for: .normal)
            button.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold),
                forImageIn: .normal
            )
        }
        return button
    }
}

struct EditorFindBar: View {
    @Binding var query: String
    var matchIndex: Int
    var matchCount: Int
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onClose: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $query)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lilCFieldInk()
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit(onNext)
                .accessibilityLabel("Find in file")
            if !query.isEmpty {
                Text(matchCount == 0 ? "0" : "\(matchIndex + 1)/\(matchCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.silver)
                    .monospacedDigit()
                    .accessibilityLabel("\(matchCount) matches")
            }
            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(matchCount == 0)
            .accessibilityLabel("Previous match")
            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .disabled(matchCount == 0)
            .accessibilityLabel("Next match")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Close find")
        }
        .foregroundStyle(AppPalette.foreground)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(AppPalette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
        }
        .onAppear { fieldFocused = true }
    }
}
