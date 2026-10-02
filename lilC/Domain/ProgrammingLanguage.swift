import Foundation

enum ProgrammingLanguage: String, CaseIterable, Identifiable, Sendable {
    case c, python, javascript, lua
    var id: String { rawValue }
    var name: String {
        switch self { case .c: "C"; case .python: "Python"; case .javascript: "JavaScript"; case .lua: "Lua" }
    }
    var fileExtension: String {
        switch self { case .c: "c"; case .python: "py"; case .javascript: "js"; case .lua: "lua" }
    }
    var directoryName: String {
        switch self { case .c: "lilC"; case .python: "lilPython"; case .javascript: "lilJavaScript"; case .lua: "lilLua" }
    }
    var selectedFileKey: String { self == .c ? "lilc.local.selected.file" : "lilc.\(rawValue).selected.file" }
    var mainFile: String { "main." + fileExtension }
    var starterName: String { "hello." + fileExtension }
    var allowedExtensions: Set<String> { self == .c ? ["c", "h"] : [fileExtension] }
    var runtimeName: String {
        switch self { case .c: "PicoC"; case .python: "CPython"; case .javascript: "JavaScriptCore"; case .lua: "Lua 5.5.1" }
    }
    var asciiArt: String {
        switch self {
        case .c: "  .----.\n  | C  |\n  '--{}'"
        case .python: "  __     \n /o \\__  \n \\__/_/  "
        case .javascript: "  .----.\n  | JS |\n  '--=>'"
        case .lua: "    . *\n  .' ) \n  '._) "
        }
    }
    var runtimeExplanation: String {
        switch self {
        case .c: "PicoC is an interpreter, not a compiler. It runs C on this iPhone. Standard C libraries and extras a desktop compiler provides will not work here."
        case .python: "CPython 3.14 runs Python on this iPhone, offline. Use print(), input(), local modules, and the bundled standard library. Installing packages, GUI libraries, subprocesses, threads, and network access are unavailable."
        case .javascript: "Apple JavaScriptCore runs JavaScript offline. Use console.log(), input(), and require('./module') for local modules. Node.js, npm, browser APIs, timers, and ES module imports are not included. Stop checks loops and functions; native operations may need to finish first."
        case .lua: "Lua 5.5.1 runs offline. Use print(), io.read(), tables, coroutines, and require() for local Lua modules. File access stays in the project. Native modules, LuaRocks, process commands, and the debug library are unavailable."
        }
    }
    var agentRules: String {
        switch self {
        case .c: "Runtime: PicoC C interpreter. Use complete simple C functions; no function pointers, qsort, system(), or external libraries. Headers need static definitions. Run one main() per project."
        case .python: "Runtime: CPython 3.14.7, offline console. Use .py files, four-space indentation, print(), input(), and local imports. Run the selected script. No pip, GUI, subprocesses, threads, network, ctypes, or native installs. Files stay in this project. Use the bundled standard library; do not invent installed packages."
        case .javascript: "Runtime: Apple JavaScriptCore, offline console. Use .js, console.log(), input(prompt) (null at EOF), local CommonJS require('./module') and module.exports. Run selected script. No Node.js, npm, DOM, fetch, timers, ES import/export, eval, or Function constructors. Use readFile(path)/writeFile(path,text) for project text files."
        case .lua: "Runtime: Lua 5.5.1, offline. Use .lua, print(), io.read(), io.write(), io.open(), and require('module') for project Lua modules. Run selected script. No LuaRocks, native modules, debug library, os.execute/exit, or io.popen. Files must stay in this project."
        }
    }
    static let pythonStarter = "def add(a, b):\n    return a + b\n\n\nprint(\"hello from lilC\")\nprint(add(5, 5))\n"
    var scriptStarter: String {
        switch self {
        case .python: Self.pythonStarter
        case .javascript: "function add(a, b) {\n    return a + b;\n}\n\nconsole.log(\"hello from lilC\");\nconsole.log(add(5, 5));\n"
        case .lua: "local function add(a, b)\n    return a + b\nend\n\nprint(\"hello from lilC\")\nprint(add(5, 5))\n"
        case .c: ""
        }
    }
    func normalizedName(_ name: String) -> String {
        if self == .c { return LocalCFile.normalizedName(name) }
        var stem = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "." + fileExtension
        if stem.lowercased().hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        stem = String(stem.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if stem.isEmpty { stem = "program" }
        if stem.first?.isNumber == true { stem = "module_" + stem }
        return stem + suffix
    }
}

enum PythonDiagnostics {
    static func jump(output: String, files: [LocalCFile], root: URL, fallback: LocalCFile) -> CErrorJump? {
        let patterns = [#"File "([^"]+)", line ([0-9]+)"#, #"(?:file://)?([^\s@]+\.(?:js|lua)):([0-9]+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed() {
                let path = ns.substring(with: match.range(at: 1)).removingPercentEncoding ?? ns.substring(with: match.range(at: 1))
                let line = Int(ns.substring(with: match.range(at: 2))) ?? 1
                if let file = files.first(where: { root.appendingPathComponent($0.name).path == path || path.hasSuffix("/" + $0.relativePath) || path == $0.name }) {
                    return CErrorJump(fileID: file.id, line: line, column: 1)
                }
            }
        }
        return nil
    }
}
