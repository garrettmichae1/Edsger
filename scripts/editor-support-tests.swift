import Foundation

private struct Failure: Error { var message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(message: message) }
}

#if os(Linux)
// Linux has no JavaScriptCore or iOS Python bundle. Only those platform boundaries
// are replaced; workspace, diagnostics, persistence, and PicoC are production code.
final class LocalPythonRunner: LocalScriptRunning, @unchecked Sendable {
    func stop() {}
    func input(_ line: String) {}
    func eof() {}
    func run(path: URL, root: URL, onOutput: @escaping @Sendable (String) -> Void,
             onWaiting: @escaping @Sendable (Bool) -> Void) -> ScriptRunResult {
        .init(output: "  File \"\(path.path)\", line 2\nSyntaxError: invalid syntax\n", failed: true, stopped: false)
    }
}
typealias LocalJavaScriptRunner = LocalPythonRunner
typealias LocalLuaRunner = LocalPythonRunner
#endif

@main
struct EditorSupportTests {
    @MainActor
    static func main() throws {
        try coordinates()
        try synchronization()
        try indentation()
        try runtimeLocations()
        try realLuaLocations()
        try workspaceDiagnostics()
        print("PASS: editor coordinates, synchronization, toolbar indentation, runtime mappings, and production workspace diagnostics")
    }

    static func coordinates() throws {
        let source = "a😀b\r\ncafé\r\n"
        try check(EditorTextCoordinates.lineRange(in: source, line: 1) == NSRange(location: 0, length: 4), "CRLF content range")
        try check(EditorTextCoordinates.lineRange(in: source, line: 2) == NSRange(location: 6, length: 4), "CRLF second line")
        try check(EditorTextCoordinates.lineRange(in: source, line: 3) == NSRange(location: 12, length: 0), "Empty EOF line")
        try check(EditorTextCoordinates.lineRange(in: source, line: 4) == nil, "Invalid diagnostic line must not clamp onto another line")
        try check(EditorTextCoordinates.selection(in: source, jump: .init(line: 1, column: 5, columnEncoding: .zeroBasedUTF8)) == NSRange(location: 3, length: 1), "PicoC UTF8 to UTF16")
        try check(EditorTextCoordinates.selection(in: source, jump: .init(line: 1, column: 3, columnEncoding: .zeroBasedUTF8)) == NSRange(location: 1, length: 3), "Byte offset inside emoji stays at scalar boundary")
        try check(EditorTextCoordinates.selection(in: source, jump: .init(line: 1, column: 3)) == NSRange(location: 1, length: 3), "Do not split surrogate pair")
        try check(EditorTextCoordinates.selection(in: "\tx", jump: .init(line: 1, column: 1, columnEncoding: .zeroBasedUTF8)) == NSRange(location: 1, length: 1), "PicoC tabs count as one byte")
        try check(EditorTextCoordinates.selection(in: "x", jump: .init(line: 1, column: Int.max)) == NSRange(location: 1, length: 0), "Large column is bounded")
        try check(EditorTextCoordinates.selection(in: "", jump: .init(line: 1, column: 0)) == NSRange(location: 0, length: 0), "Empty buffer")
        try check(EditorTextCoordinates.clampedSelection(.init(location: 2, length: 0), in: "a😀b") == .init(location: 1, length: 0), "External edits cannot leave caret inside surrogate")
        try check(EditorTextCoordinates.clampedSelection(.init(location: 0, length: 2), in: "a😀b") == .init(location: 0, length: 3), "Selection end cannot split surrogate")
        try check(EditorSearch.nsMatches(in: "😀Abc abc", query: "ABC") == [NSRange(location: 2, length: 3), NSRange(location: 6, length: 3)], "Search uses UTF16 and remains case insensitive")
        let diagnostic = EditorRuntimeDiagnostic(jump: .init(fileID: "main.c", line: 2, column: 1), message: "Runtime error")
        try check(diagnostic.range(in: "x\n\ny") == NSRange(location: 2, length: 1), "Empty interior line marker")
        try check(diagnostic.range(in: "x\n") == nil, "Empty EOF marker does not exceed buffer")
        print("PASS: Unicode, byte columns, CRLF/CR/LF, EOF, invalid locations, and search")
    }

    static func synchronization() throws {
        try check(!CCodeEditorKeyboardPolicy.shouldApplyBoundText(fileChanged: false, isFirstResponder: true, viewText: "typing", boundText: "old", lastPublishedText: "old"), "Ignore stale binding echo")
        try check(CCodeEditorKeyboardPolicy.shouldApplyBoundText(fileChanged: false, isFirstResponder: true, viewText: "typing", boundText: "AI edit", lastPublishedText: "typing"), "Apply external AI edit while focused")
        try check(!CCodeEditorKeyboardPolicy.shouldApplyBoundText(fileChanged: false, isFirstResponder: true, viewText: "composing", boundText: "AI edit", lastPublishedText: "old", hasMarkedText: true), "Protect input composition")
        try check(CCodeEditorKeyboardPolicy.shouldApplyBoundText(fileChanged: true, isFirstResponder: true, viewText: "old file", boundText: "new file", hasMarkedText: true), "File switches replace old document")
        try check(!CCodeEditorKeyboardPolicy.shouldResignFirstResponder(swiftUIWantsFocus: false, textViewIsFirstResponder: true), "Typing must not dismiss keyboard")
        print("PASS: focused AI updates, binding echoes, document switches, and keyboard policy")
    }

    static func indentation() throws {
        let text = "a\r\nb\r\n"
        let indented = EditorIndentation.apply(to: text, selection: .init(location: 0, length: 4), outdent: false)
        try check(indented.text == "    a\r\n    b\r\n", "Indent selected lines without changing CRLF")
        let out = EditorIndentation.apply(to: indented.text, selection: indented.selection, outdent: true)
        try check(out.text == text, "Outdent roundtrip")
        try check(EditorIndentation.apply(to: "", selection: .init(location: 0, length: 0), outdent: false).text == "    ", "Indent empty file")
        try check(EditorIndentation.apply(to: "a\n", selection: .init(location: 2, length: 0), outdent: false).text == "a\n    ", "Indent final empty line")
        try check(EditorIndentation.apply(to: "\tx", selection: .init(location: 1, length: 0), outdent: true).text == "x", "Outdent tabs")
        try check(EditorIndentation.apply(to: "a\nb", selection: .init(location: 0, length: 2), outdent: false).text == "    a\nb", "Selection ending at next line does not indent it")
        let format = CIndentFormatter.formatKeepingCaret("int main(void) {\r\nreturn 0;\r\n}\r\n", caretUTF16: 20)
        try check(format.text == "int main(void) {\r\n    return 0;\r\n}\r\n", "Existing formatter preserves line endings")
        print("PASS: toolbar selection arithmetic and production C formatter")
    }

    static func runtimeLocations() throws {
        let helper = LocalCFile(relativePath: "proj/util.c", code: "int add(void) {\n    return 1\n}\n")
        let main = LocalCFile(relativePath: "proj/main.c", code: "int main(void) { return add(); }\n")
        let raw = LocalCRunner.run(CDiagnosticJump.concatenatedSource(runFile: main, extras: [helper]))
        guard let diagnostic = CDiagnosticFormatter.diagnostic(from: raw),
              let jump = CDiagnosticJump.resolve(diagnostic: diagnostic, runFile: main, extras: [helper], projectFiles: [helper, main]) else { throw Failure(message: "Real PicoC output did not map: \(raw)") }
        try check(jump.fileID == helper.id, "Real PicoC concatenated helper mapping")
        try check(jump.columnEncoding == .zeroBasedUTF8, "Real PicoC byte-column convention")
        let root = URL(fileURLWithPath: "/tmp/runstone-project")
        let python = LocalCFile(relativePath: "proj/main.py", code: "import helper\n")
        let pyHelper = LocalCFile(relativePath: "proj/sub/helper.py", code: "raise ValueError()\n")
        let py = "Traceback (most recent call last):\n  File \"/tmp/runstone-project/main.py\", line 1, in <module>\n  File \"/tmp/runstone-project/sub/helper.py\", line 2, in fail\nValueError: bad\n"
        try check(PythonDiagnostics.jump(output: py, files: [python, pyHelper], root: root, fallback: python)?.fileID == pyHelper.id, "Python innermost nested helper")
        let js = LocalCFile(relativePath: "proj/main.js", code: "fail();")
        let jsHelper = LocalCFile(relativePath: "proj/sub/helper.js", code: "throw Error();")
        let jsOutput = "Error: bad\nfail@file:///tmp/runstone-project/sub/helper.js:3:40\nmain@file:///tmp/runstone-project/main.js:7:60\n"
        let jsJump = PythonDiagnostics.jump(output: jsOutput, files: [js, jsHelper], root: root, fallback: js)
        try check(jsJump?.fileID == jsHelper.id && jsJump?.line == 3 && jsJump?.column == 1, "JavaScript first frame; ignore instrumented runtime columns")
        let syntax = PythonDiagnostics.jump(output: "SyntaxError: unexpected token\nmain.js:2:9\n", files: [js], root: root, fallback: js)
        try check(syntax?.column == 9, "Acorn syntax columns refer to original source")
        let lua = LocalCFile(relativePath: "proj/main.lua", code: "require('helper')")
        let luaHelper = LocalCFile(relativePath: "proj/helper.lua", code: "error('bad')")
        let luaOutput = "/tmp/runstone-project/helper.lua:2: bad\nstack traceback:\n\t/tmp/runstone-project/main.lua:7: in main chunk"
        try check(PythonDiagnostics.jump(output: luaOutput, files: [lua, luaHelper], root: root, fallback: lua)?.fileID == luaHelper.id, "Lua error header wins over caller")
        try check(PythonDiagnostics.jump(output: "Error: bad\nfile:///elsewhere/main.js:2:1", files: [js], root: root, fallback: js) == nil, "Outside-project errors do not jump to basename match")
        try check(PythonDiagnostics.jump(output: "SyntaxError\nmissing.js:2:1", files: [js], root: root, fallback: js) == nil, "Unknown filename has no guessed location")
        let snapshot = EditorDiagnosticSnapshot(diagnostic: .init(jump: jump, message: raw), files: [helper, main])
        var changed = helper; changed.code += "\n"
        try check(snapshot.matches([helper, main]), "Source snapshot valid")
        try check(!snapshot.matches([changed, main]), "Edited helper invalidates snapshot")
        try check(!snapshot.matches([main]), "Deleted helper invalidates snapshot")
        print("PASS: real PicoC errors; Python, JavaScriptCore/Acorn, and Lua location formats; stale-source snapshots")
    }

    @MainActor
    static func workspaceDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "editor-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LocalCWorkspace(defaults: defaults, directoryURL: directory)
        workspace.updateCurrentCode("int main(void) {\n    return missing;\n}\n")
        let file = workspace.currentFile
        let raw = LocalCRunner.runInteractive(file.code, mainName: file.name, onOutput: { _ in }, onWaitingForInput: { _ in })
        guard let diagnostic = CDiagnosticFormatter.diagnostic(from: raw) else { throw Failure(message: "Expected runtime diagnostic: \(raw)") }
        let jump = CDiagnosticJump.resolve(diagnostic: diagnostic, runFile: file, extras: [], projectFiles: [file])
        workspace.recordEditorDiagnostic(jump: jump, message: diagnostic.displayText, sources: [file])
        try check(workspace.currentEditorDiagnostic != nil && workspace.lastErrorJump != nil, "Workspace records editor diagnostic")
        workspace.updateCurrentCode("int main(void) { return 0; }\n")
        try check(workspace.currentEditorDiagnostic == nil && workspace.lastErrorJump == nil, "Editing clears stale marker and navigation")
        let success = LocalCRunner.run(workspace.currentFile.code)
        try check(!CDiagnosticFormatter.displayOutput(for: success).failed, "Fixed source runs successfully")
        workspace.recordEditorDiagnostic(jump: nil, message: "", sources: [])
        try check(workspace.currentEditorDiagnostic == nil, "Successful rerun clears error")
        print("PASS: production workspace persistence and diagnostic lifecycle with real runtime output")
    }

    static func realLuaLocations() throws {
        struct Fixture: Decodable {
            var name: String
            var output: String
            var diagnosticOutput: String
            var root: String
            var files: [String: String]
            var expectedFile: String
            var expectedLine: Int
        }
        guard CommandLine.arguments.count > 1 else { throw Failure(message: "Missing native Lua fixtures") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        for fixture in fixtures {
            let files = fixture.files.map { LocalCFile(relativePath: $0.key, code: $0.value) }
            let main = files.first { $0.name == "main.lua" }!
            let jump = PythonDiagnostics.jump(output: fixture.diagnosticOutput, files: files, root: URL(fileURLWithPath: fixture.root), fallback: main)
            try check(jump?.fileID == fixture.expectedFile && jump?.line == fixture.expectedLine,
                      "Native Lua \(fixture.name) mapped incorrectly: \(String(describing: jump))\n\(fixture.output)")
        }
        print("PASS: \(fixtures.count) actual Lua runtime errors, nested modules, and printed-location isolation")
    }
}
