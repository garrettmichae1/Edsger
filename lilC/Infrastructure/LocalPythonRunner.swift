import Foundation

final class LocalPythonRunner: LocalScriptRunning, @unchecked Sendable {
    typealias Result = ScriptRunResult
    private let job: OpaquePointer
    private let lock = NSLock()
    private var captured = ""
    private var outputHandler: (@Sendable (String) -> Void)?
    private var waitingHandler: (@Sendable (Bool) -> Void)?
    init() { job = lilc_python_create()! }
    deinit { lilc_python_destroy(job) }
    func stop() { lilc_python_stop(job) }
    func input(_ line: String) { lilc_python_input(job, line) }
    func eof() { lilc_python_eof(job) }
    fileprivate func receive(_ text: String) {
        lock.lock(); captured += text; let handler = outputHandler; lock.unlock()
        handler?(text)
    }
    fileprivate func waiting(_ value: Bool) {
        lock.lock(); let handler = waitingHandler; lock.unlock(); handler?(value)
    }
    func run(path: URL, root: URL, onOutput: @escaping @Sendable (String) -> Void,
             onWaiting: @escaping @Sendable (Bool) -> Void) -> Result {
        lock.lock(); outputHandler = onOutput; waitingHandler = onWaiting; lock.unlock()
        let bundle = Bundle.main.bundleURL
        let home = bundle.appendingPathComponent("python").path
        let bootstrap = bundle.appendingPathComponent("python_bootstrap.py").path
        let context = Unmanaged.passUnretained(self).toOpaque()
        let code = lilc_python_run(job, home, bootstrap, path.path, root.path, pythonOutput, pythonWaiting, context)
        lock.lock(); let output = captured; outputHandler = nil; waitingHandler = nil; lock.unlock()
        return Result(output: output, failed: code == 1, stopped: code == 2)
    }
}

private func pythonOutput(_ bytes: UnsafePointer<CChar>?, _ count: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let bytes, let context else { return }
    let data = UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(count))
    Unmanaged<LocalPythonRunner>.fromOpaque(context).takeUnretainedValue().receive(String(decoding: data, as: UTF8.self))
}
private func pythonWaiting(_ waiting: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LocalPythonRunner>.fromOpaque(context).takeUnretainedValue().waiting(waiting != 0)
}
