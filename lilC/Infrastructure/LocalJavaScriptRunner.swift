import Foundation
import JavaScriptCore

final class LocalJavaScriptRunner: LocalScriptRunning, @unchecked Sendable {
    private let console = ScriptConsole()
    func stop() { console.stop() }
    func input(_ line: String) { console.input(line) }
    func eof() { console.eof() }
    func run(path: URL, root: URL, onOutput: @escaping @Sendable (String) -> Void, onWaiting: @escaping @Sendable (Bool) -> Void) -> ScriptRunResult {
        console.onOutput = onOutput; console.onWaiting = onWaiting
        guard !console.isStopped else { return .init(output: "", failed: false, stopped: true) }
        guard let context = JSContext() else { return .init(output: "Could not initialize JavaScriptCore.", failed: true, stopped: false) }
        var errorText: String?
        var diagnosticText: String?
        context.exceptionHandler = { _, error in
            guard let error, errorText == nil else { return }
            let message = error.toString() ?? "JavaScript error"
            let stack = error.forProperty("stack")?.toString() ?? ""
            let line = error.forProperty("line")?.toInt32() ?? 0
            errorText = "\(message)\n\(stack.isEmpty ? "\(path.lastPathComponent):\(max(1, line))" : Self.sourceStack(stack))\n"
            let source = error.forProperty("sourceURL")?.toString() ?? ""
            let location = stack.isEmpty ? (line > 0 && !source.isEmpty ? "\(source):\(line)" : "") : Self.sourceStack(stack)
            diagnosticText = "\(message)\n\(location)\n"
        }
        func raise(_ error: Error) { JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current()) }
        let write: @convention(block) (String) -> Void = { [console] text in do { try console.write(text) } catch { raise(error) } }
        let input: @convention(block) () -> Any = { [console] in
            let value = console.readLine()?.trimmingCharacters(in: .newlines)
            if console.isStopped { raise(ScriptError.message("Stopped.")) }
            return value as Any? ?? NSNull()
        }
        let stopped: @convention(block) () -> Bool = { [console] in console.isStopped }
        let read: @convention(block) (String) -> String? = { name in
            do { return try String(contentsOf: projectFile(name, root: root), encoding: .utf8) } catch { raise(error); return nil }
        }
        let save: @convention(block) (String, String) -> Void = { name, text in
            do { try text.write(to: projectFile(name, root: root), atomically: true, encoding: .utf8) } catch { raise(error) }
        }
        let resolve: @convention(block) (String) -> String? = { name in
            do { let file = try projectFile(name, root: root); return String(file.path.dropFirst(root.resolvingSymlinksInPath().path.count + 1)) } catch { raise(error); return nil }
        }
        let compile: @convention(block) (String, String) -> JSValue? = { source, name in
            do {
                let url = try projectFile(name, root: root)
                // Keep the opening wrapper on the first source line so traceback lines stay exact.
                return JSContext.current()?.evaluateScript("(function(require,module,exports){" + source + "\n})", withSourceURL: url)
            } catch { raise(error); return nil }
        }
        context.setObject(compile, forKeyedSubscript: "__lilc_compile" as NSString)
        for (name, value) in [("__lilc_write",write as Any),("__lilc_input",input as Any),("__lilc_stopped",stopped as Any),("__lilc_read",read as Any),("__lilc_writeFile",save as Any),("__lilc_resolve",resolve as Any)] { context.setObject(value, forKeyedSubscript: name as NSString) }
        do {
            for file in ["acorn.js", "javascript_bootstrap.js"] {
                let url = Bundle.main.bundleURL.appendingPathComponent(file)
                context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
                if errorText != nil { break }
            }
            if errorText == nil { context.objectForKeyedSubscript("__lilc_run")?.call(withArguments: [path.lastPathComponent]) }
        } catch { errorText = error.localizedDescription }
        let stoppedResult = console.isStopped
        if let errorText, !stoppedResult { try? console.write(errorText) }
        return .init(output: console.output, failed: errorText != nil && !stoppedResult, stopped: stoppedResult, diagnosticOutput: diagnosticText)
    }
    private static func sourceStack(_ stack: String) -> String {
        stack.components(separatedBy: "\n").filter { !$0.contains("javascript_bootstrap.js") && !$0.contains("acorn.js") }.joined(separator: "\n")
    }
}
