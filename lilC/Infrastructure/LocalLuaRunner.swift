import Foundation

final class LocalLuaRunner: LocalScriptRunning, @unchecked Sendable {
    typealias Result = ScriptRunResult
    private let job: OpaquePointer
    private let lock = NSLock()
    private var captured = ""
    private var outputHandler: (@Sendable (String) -> Void)?
    private var waitingHandler: (@Sendable (Bool) -> Void)?
    init() { job = lilc_lua_create()! }
    deinit { lilc_lua_destroy(job) }
    func stop() { lilc_lua_stop(job) }
    func input(_ line: String) { lilc_lua_input(job, line) }
    func eof() { lilc_lua_eof(job) }
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
        let bootstrap = bundle.appendingPathComponent("lua_bootstrap.lua").path
        let context = Unmanaged.passUnretained(self).toOpaque()
        let code = lilc_lua_run(job, bootstrap, path.path, root.path, luaOutput, luaWaiting, context)
        lock.lock(); let output = captured; outputHandler = nil; waitingHandler = nil; lock.unlock()
        return Result(output: output, failed: code == 1, stopped: code == 2)
    }
}

private func luaOutput(_ bytes: UnsafePointer<CChar>?, _ count: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let bytes, let context else { return }
    let data = UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(count))
    Unmanaged<LocalLuaRunner>.fromOpaque(context).takeUnretainedValue().receive(String(decoding: data, as: UTF8.self))
}
private func luaWaiting(_ waiting: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LocalLuaRunner>.fromOpaque(context).takeUnretainedValue().waiting(waiting != 0)
}
