import Foundation

/// Python access is serialized by the existing C engine lock. Never waits behind an IDE run.
actor LocalMathCalculator: IntegralWorkCalculating {
    static let shared = LocalMathCalculator()
    private var cache: [String: MathCalculation] = [:]

    func calculate(_ request: MathRequest) async throws -> MathCalculation {
        try await calculate(request, includeWork: false)
    }

    func calculateIntegralWork(_ request: MathRequest) async throws -> MathCalculation {
        guard request.operation == "integrate" else { return .unavailable("Integral work requires an integral request.") }
        return try await calculate(request, includeWork: true)
    }

    private func calculate(_ request: MathRequest, includeWork: Bool) async throws -> MathCalculation {
        try Task.checkCancellation()
        guard request.isValid else { return .unavailable("Unsupported calculation request.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(request)
        if includeWork {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unavailable("The calculator request could not be encoded.")
            }
            object["include_work"] = true
            data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
        let json = String(decoding: data, as: UTF8.self)
        if let cached = cache[json] { return cached }
        let job = MathJob()
        // Startup has its own budget in the native bridge.
        let seconds = 8.0
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: job.run(json, seconds: seconds))
                }
            }
        } onCancel: { job.stop() }
        try Task.checkCancellation()
        if result.ok {
            if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
            cache[json] = result
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
        if status == 5 { return .unavailable("The math engine took too long to start. Please try again.") }
        if status == 4 { return .unavailable("The calculation exceeded its time limit. Try a simpler expression.") }
        if status == 2 { return .unavailable("Calculation stopped.") }
        if status != 0 { return .unavailable("The on-device math engine could not complete this request. Try again.") }
        guard status == 0, let result = try? JSONDecoder().decode(MathCalculation.self, from: Data(output.utf8)) else {
            return .unavailable("The math engine returned an unreadable result. Try again.")
        }
        return result
    }
}

// Keep concrete app dependencies out of the portable domain layer.
extension CalculatingTutorClient {
    static let shared = Self(tutor: LocalAgentClient.shared, planner: LocalAgentClient.shared,
                             calculator: LocalMathCalculator.shared)
}
