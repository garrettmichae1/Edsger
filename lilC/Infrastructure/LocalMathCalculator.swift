import Foundation

/// Python access is serialized by the existing C engine lock. Never waits behind an IDE run.
actor LocalMathCalculator: MathCalculating {
    static let shared = LocalMathCalculator()
    private var cache: [String: MathCalculation] = [:]
    private var warmed = false

    func calculate(_ request: MathRequest) async throws -> MathCalculation {
        try Task.checkCancellation()
        guard request.isValid else { return .unavailable("Unsupported calculation request.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        if let cached = cache[json] { return cached }
        let job = MathJob()
        let seconds = warmed ? 2.0 : 8.0
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: job.run(json, seconds: seconds))
                }
            }
        } onCancel: { job.stop() }
        try Task.checkCancellation()
        if result.ok {
            warmed = true
            if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
            cache[json] = result
        } else {
            // The host may have discarded an interrupted interpreter. Allow a cold-start budget next time.
            warmed = false
        }
        return result
    }
}

private final class MathJob: @unchecked Sendable {
    private let job = lilc_python_create()
    // Only accessed on the execution thread, including the synchronous C callback.
    var output = ""
    deinit { if let job { lilc_python_destroy(job) } }
    func stop() { if let job { lilc_python_stop(job) } }
    func run(_ request: String, seconds: Double) -> MathCalculation {
        guard let job else { return .unavailable("The calculator could not reserve memory. Try again.") }
        let bundle = Bundle.main.bundleURL
        let status = lilc_python_calculate(job, bundle.appendingPathComponent("python").path,
            bundle.appendingPathComponent("math_bootstrap.py").path,
            bundle.appendingPathComponent("math-packages").path, request, seconds,
            { bytes, count, context in
                guard let bytes, let context else { return }
                let owner = Unmanaged<MathJob>.fromOpaque(context).takeUnretainedValue()
                owner.output += String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(count)), as: UTF8.self)
            }, Unmanaged.passUnretained(self).toOpaque())
        if status == 3 { return .unavailable("Python is busy. Stop the active run or wait for it to finish, then try again.") }
        if status == 4 { return .unavailable("The calculation exceeded its time limit. Try a simpler expression.") }
        if status == 2 { return .unavailable("Calculation stopped.") }
        guard status == 0, let result = try? JSONDecoder().decode(MathCalculation.self, from: Data(output.utf8)) else {
            return .unavailable("The calculation exceeded its time limit or the math engine was unavailable.")
        }
        return result
    }
}

// Keep concrete app dependencies out of the portable domain layer.
extension CalculatingTutorClient {
    static let shared = Self(tutor: LocalAgentClient.shared, planner: LocalAgentClient.shared,
                             calculator: LocalMathCalculator.shared)
}
