import Foundation

enum EditorColumnEncoding: Equatable, Sendable {
    case oneBasedUTF16
    /// PicoC's lexer counts bytes from zero, including tabs as one byte.
    case zeroBasedUTF8
}

struct CaretJump: Equatable {
    var id: UUID
    var line: Int
    var column: Int
    var columnEncoding: EditorColumnEncoding
    var fileID: String?

    init(line: Int, column: Int, columnEncoding: EditorColumnEncoding = .oneBasedUTF16, fileID: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.line = line
        self.column = column
        self.columnEncoding = columnEncoding
        self.fileID = fileID
    }
}

enum EditorSearch {
    static func nsMatches(in text: String, query: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let haystack = text as NSString
        var matches: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while search.length > 0 {
            let found = haystack.range(of: needle, options: [.caseInsensitive], range: search)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            let next = NSMaxRange(found)
            guard next < haystack.length else { break }
            search = NSRange(location: next, length: haystack.length - next)
        }
        return matches
    }
}

enum CCodeEditorKeyboardPolicy {
    static func shouldResignFirstResponder(swiftUIWantsFocus: Bool, textViewIsFirstResponder: Bool) -> Bool {
        false
    }

    static func shouldBecomeFirstResponder(swiftUIWantsFocus: Bool, textViewIsFirstResponder: Bool) -> Bool {
        swiftUIWantsFocus && !textViewIsFirstResponder
    }

    static func shouldApplyBoundText(
        fileChanged: Bool, isFirstResponder: Bool, viewText: String, boundText: String,
        lastPublishedText: String? = nil, hasMarkedText: Bool = false
    ) -> Bool {
        if fileChanged { return viewText != boundText }
        guard viewText != boundText, !hasMarkedText else { return false }
        // A binding echo must never replace an in-progress keystroke. An actual
        // external update (for example an AI edit) must apply even while focused.
        if let lastPublishedText { return boundText != lastPublishedText }
        return !isFirstResponder
    }
}

enum EditorTextCoordinates {
    /// Content only, excluding CR/LF. The final empty line is a valid location.
    static func lineRange(in text: String, line: Int) -> NSRange? {
        guard line > 0 else { return nil }
        let ns = text as NSString
        var current = 1
        var start = 0
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 10 || unit == 13 {
                if current == line { return NSRange(location: start, length: index - start) }
                index += 1
                if unit == 13, index < ns.length, ns.character(at: index) == 10 { index += 1 }
                start = index
                current += 1
            } else {
                index += 1
            }
        }
        return current == line ? NSRange(location: start, length: ns.length - start) : nil
    }

    static func selection(in text: String, jump: CaretJump) -> NSRange? {
        guard let line = lineRange(in: text, line: jump.line) else { return nil }
        let content = (text as NSString).substring(with: line)
        let offset: Int
        switch jump.columnEncoding {
        case .oneBasedUTF16:
            let units = Array(content.utf16)
            var clamped = min(max(jump.column, 1) - 1, units.count)
            if clamped > 0, clamped < units.count,
               (0xDC00...0xDFFF).contains(units[clamped]), (0xD800...0xDBFF).contains(units[clamped - 1]) {
                clamped -= 1
            }
            offset = clamped
        case .zeroBasedUTF8:
            var bytes = 0
            var utf16 = 0
            for scalar in content.unicodeScalars {
                let byteCount = scalar.utf8.count
                guard bytes + byteCount <= max(jump.column, 0) else { break }
                bytes += byteCount
                utf16 += scalar.utf16.count
            }
            offset = utf16
        }
        return NSRange(location: line.location + offset, length: line.length - offset)
    }

    static func clampedSelection(_ selection: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let length = ns.length
        var location = min(max(selection.location, 0), length)
        var end = location + min(max(selection.length, 0), length - location)
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < length && (0xDC00...0xDFFF).contains(ns.character(at: offset))
                && (0xD800...0xDBFF).contains(ns.character(at: offset - 1))
        }
        if splitsSurrogate(location) { location -= 1 }
        if selection.length == 0 { end = location }
        else if splitsSurrogate(end) { end += 1 }
        return NSRange(location: location, length: end - location)
    }
}

struct EditorRuntimeDiagnostic: Equatable {
    var jump: CErrorJump
    var message: String

    func range(in text: String) -> NSRange? {
        guard let line = EditorTextCoordinates.lineRange(in: text, line: jump.line) else { return nil }
        if line.length > 0 { return line }
        // An empty interior line can highlight its line break. An empty EOF line
        // remains navigable but must not manufacture an out-of-bounds range.
        return line.location < (text as NSString).length ? NSRange(location: line.location, length: 1) : nil
    }
}

struct EditorDiagnosticSnapshot {
    var diagnostic: EditorRuntimeDiagnostic
    var sources: [String: String]

    init(diagnostic: EditorRuntimeDiagnostic, files: [LocalCFile]) {
        self.diagnostic = diagnostic
        self.sources = Dictionary(files.map { ($0.id, $0.code) }, uniquingKeysWith: { _, last in last })
    }

    func matches(_ files: [LocalCFile]) -> Bool {
        sources.allSatisfy { id, code in files.contains { $0.id == id && $0.code == code } }
    }
}

/// Four-space toolbar indentation, including the final empty line. Kept separate
/// from the text view so selection arithmetic can be tested without UIKit.
enum EditorIndentation {
    static func apply(to text: String, selection: NSRange, outdent: Bool) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let selected = EditorTextCoordinates.clampedSelection(selection, in: text)
        let end = selected.length == 0 ? selected.location : NSMaxRange(selected) - 1
        var starts: [Int] = []
        var cursor = ns.lineRange(for: NSRange(location: selected.location, length: 0)).location
        while cursor <= end {
            starts.append(cursor)
            if cursor == ns.length { break }
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: cursor, length: 0)))
            guard next > cursor else { break }
            cursor = next
        }
        let mutable = NSMutableString(string: text)
        var delta = 0
        var firstDelta = 0
        for (index, start) in starts.enumerated() {
            let location = start + delta
            let change: Int
            if outdent {
                var removed = 0
                while removed < 4, location < mutable.length {
                    let unit = mutable.character(at: location)
                    if unit == 32 { mutable.deleteCharacters(in: NSRange(location: location, length: 1)); removed += 1 }
                    else if unit == 9, removed == 0 { mutable.deleteCharacters(in: NSRange(location: location, length: 1)); removed = 1; break }
                    else { break }
                }
                change = -removed
            } else {
                mutable.insert("    ", at: location)
                change = 4
            }
            if index == 0 { firstDelta = change }
            delta += change
        }
        let result = mutable as String
        let range = NSRange(location: max(0, selected.location + firstDelta), length: max(0, selected.length + delta - firstDelta))
        return (result, EditorTextCoordinates.clampedSelection(range, in: result))
    }
}
