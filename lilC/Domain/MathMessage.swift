import Foundation

/// Delimiters belong to presentation only; saved messages retain their original text.
enum MathMessage {
    enum Inline: Equatable {
        case text(String)
        case math(String)
    }
    enum Block: Equatable {
        case prose([Inline])
        case equation(String)
        case code(language: String, source: String)
    }

    static func parse(_ source: String) -> [Block] {
        let chars = Array(source)
        var blocks: [Block] = []
        var inline: [Inline] = []
        var text = ""
        var i = 0
        func matches(_ token: String, at index: Int) -> Bool {
            let token = Array(token)
            return index + token.count <= chars.count && Array(chars[index..<(index + token.count)]) == token
        }
        func escaped(_ index: Int) -> Bool {
            var count = 0
            var j = index
            while j > 0 && chars[j - 1] == "\\" { count += 1; j -= 1 }
            return !count.isMultiple(of: 2)
        }
        func end(of token: String, from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if matches(token, at: j) && !escaped(j) { return j }
                j += 1
            }
            return nil
        }
        func flushText() {
            if !text.isEmpty { inline.append(.text(text)); text = "" }
        }
        func flushProse() {
            flushText()
            if case .text(let first) = inline.first {
                inline[0] = .text(String(first.drop(while: { $0.isNewline })))
            }
            if case .text(let last) = inline.last {
                inline[inline.count - 1] = .text(String(last.reversed().drop(while: { $0.isNewline }).reversed()))
            }
            inline.removeAll { if case .text(let value) = $0 { return value.isEmpty }; return false }
            if !inline.isEmpty { blocks.append(.prose(inline)); inline = [] }
        }
        while i < chars.count {
            // Consume code before looking for math, including unfinished streamed fences.
            if matches("```", at: i) {
                flushProse()
                let start = i + 3
                let close = end(of: "```", from: start) ?? chars.count
                let contents = String(chars[start..<close])
                if let newline = contents.firstIndex(of: "\n") {
                    blocks.append(.code(language: String(contents[..<newline]), source: String(contents[contents.index(after: newline)...]).trimmingCharacters(in: .newlines)))
                } else {
                    blocks.append(.code(language: "", source: contents))
                }
                i = min(close + 3, chars.count)
                continue
            }
            if chars[i] == "`" && !escaped(i) {
                var ticks = 1
                while i + ticks < chars.count && chars[i + ticks] == "`" { ticks += 1 }
                let delimiter = String(repeating: "`", count: ticks)
                let close = end(of: delimiter, from: i + ticks)
                let stop = close.map { $0 + ticks } ?? chars.count
                text += String(chars[i..<stop]); i = stop
                continue
            }
            var delimiter: (open: String, close: String, display: Bool)?
            if !escaped(i) {
                if matches("\\[", at: i) { delimiter = ("\\[", "\\]", true) }
                else if matches("\\(", at: i) { delimiter = ("\\(", "\\)", false) }
                else if matches("$$", at: i) { delimiter = ("$$", "$$", true) }
                else if chars[i] == "$", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                    delimiter = ("$", "$", false)
                }
            }
            if let delimiter {
                let start = i + delimiter.open.count
                if let close = end(of: delimiter.close, from: start) {
                    let body = String(chars[start..<close])
                    // Currency such as "$5 and $10" must remain ordinary prose.
                    let validDollar = delimiter.open != "$" ||
                        (!body.isEmpty && !body.contains("\n") && !chars[close - 1].isWhitespace &&
                         (close + 1 == chars.count || !chars[close + 1].isNumber))
                    if validDollar && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if delimiter.display {
                            flushProse(); blocks.append(.equation(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } else {
                            flushText(); inline.append(.math(body))
                        }
                        i = close + delimiter.close.count
                        continue
                    }
                } else if delimiter.open != "$" {
                    // Do not typeset partial LaTeX or reinterpret its contents while streaming.
                    text += String(chars[i...]); i = chars.count
                    continue
                }
            }
            text.append(chars[i]); i += 1
        }
        flushProse()
        return blocks
    }
}
