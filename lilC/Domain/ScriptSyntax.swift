import Foundation

enum ScriptSyntax {
    static func tokens(in source: String, language: ProgrammingLanguage) -> [CSyntaxToken] {
        if language == .c { return CSyntaxLexer.tokens(in: source) }
        if language == .python { return PythonSyntax.tokens(in: source) }
        let comments = language == .lua ? #"--\[\[[\s\S]*?\]\]|--[^\n]*"# : #"/\*[\s\S]*?\*/|//[^\n]*"#
        let keywords = language == .lua ? "and|break|do|else|elseif|end|false|for|function|goto|if|in|local|nil|not|or|repeat|return|then|true|until|while" : "async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|false|finally|for|function|if|import|in|instanceof|let|new|null|of|return|static|super|switch|this|throw|true|try|typeof|undefined|var|void|while|yield"
        let pattern = comments + #"|\"(?:\\.|[^\"\\])*\"?|'(?:\\.|[^'\\])*'?|`(?:\\.|[^`\\])*`?|\b(?:"# + keywords + #")\b|\b\d+(?:\.\d+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0,length: ns.length)).map { match in
            let text = ns.substring(with: match.range)
            let kind: CSyntaxKind = text.hasPrefix("--") || text.hasPrefix("//") || text.hasPrefix("/*") ? .comment : (text.first == "\"" || text.first == "'" || text.first == "`" ? .string : (text.first?.isNumber == true ? .number : .control))
            return CSyntaxToken(kind: kind, range: match.range)
        }
    }
    static func newlineIndent(before text: String, language: ProgrammingLanguage) -> String {
        if language == .python { return PythonSyntax.newlineIndent(before: text) }
        let line = text.components(separatedBy: "\n").last ?? ""
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let clean = line.trimmingCharacters(in: .whitespaces)
        let opens = language == .javascript ? clean.hasSuffix("{") : (clean.hasSuffix("then") || clean.hasSuffix("do") || clean == "else" || clean == "repeat" || clean.contains("function") && clean.hasSuffix(")"))
        return "\n" + indent + (opens ? "    " : "")
    }
}
