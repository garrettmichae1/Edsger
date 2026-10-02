import Foundation

enum PythonSyntax {
    static func tokens(in source: String) -> [CSyntaxToken] {
        let pattern = #"(?s:\"\"\".*?(?:\"\"\"|\z)|'''.*?(?:'''|\z))|\"(?:\\.|[^\"\\\n])*\"?|'(?:\\.|[^'\\\n])*'?|#[^\n]*|\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|match|case)\b|\b\d+(?:\.\d+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            let token = ns.substring(with: match.range)
            let kind: CSyntaxKind = token.hasPrefix("#") ? .comment : (token.hasPrefix("\"") || token.hasPrefix("'") ? .string : (token.first?.isNumber == true ? .number : .control))
            return CSyntaxToken(kind: kind, range: match.range)
        }
    }
    static func newlineIndent(before text: String) -> String {
        let line = text.components(separatedBy: "\n").last ?? ""
        let prefix = String(line.prefix { $0 == " " || $0 == "\t" })
        let code = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        return "\n" + prefix + (code.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? "    " : "")
    }
}
