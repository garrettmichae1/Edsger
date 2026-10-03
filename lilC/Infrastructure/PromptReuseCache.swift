import Foundation

/// Sequence state includes attention AND recurrent memory. Implementations must not
/// restore untrusted bytes or reuse a context identity after replacing its model.
protocol PromptStateBackend {
    var contextID: UUID { get }
    func clear()
    func decode(_ tokens: ArraySlice<Int32>) throws
    func synchronize()
    func canCapture(bytes: Int) -> Bool
    func stateSize() -> Int
    func save(into buffer: UnsafeMutableRawBufferPointer) -> Int
    func restore(from buffer: UnsafeRawBufferPointer) -> Int
}

/// A warning can arrive while synchronous inference occupies the actor. Poll this
/// small signal between batches/tokens instead of queueing eviction behind inference.
final class PromptCachePressure: @unchecked Sendable {
    private let lock = NSLock()
    private var disabled = false
    func disable() { lock.withLock { disabled = true } }
    var isDisabled: Bool { lock.withLock { disabled } }
}

enum InferenceClock {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock().now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

/// Actor-owned, single-entry, in-memory cache. It never retains generated output.
/// Alignment preserves the normal 256-token decode boundaries on cache hits.
struct PromptReuseCache {
    static let batchSize = 256
    static let defaultByteLimit = 96 * 1024 * 1024
    static let maximumPrefixTokens = 1024

    struct Metrics: Sendable {
        var outcome = "empty"
        var capture = "skipped"
        var reusedTokens = 0
        var decodedTokens = 0
        var retainedBytes = 0
        var restoreSeconds = 0.0
        var captureSeconds = 0.0
        var decodeSeconds = 0.0
    }
    private struct Entry {
        let contextID: UUID
        let tokens: [Int32]
        let state: Data
        var byteCount: Int { state.count + tokens.count * MemoryLayout<Int32>.stride }
    }
    private var entry: Entry?
    let byteLimit: Int
    var retainedBytes: Int { entry?.byteCount ?? 0 }

    init(byteLimit: Int = Self.defaultByteLimit) { self.byteLimit = max(0, byteLimit) }
    mutating func removeAll() { entry = nil }

    /// Only checkpoint tokens belonging to complete messages, before the fresh
    /// assistant marker. The end token comes from this model's tokenizer.
    static func checkpointCount(tokens: [Int32], messageEndToken: Int32?) -> Int {
        guard let messageEndToken, let end = tokens.lastIndex(of: messageEndToken) else { return 0 }
        let available = min(end + 1, tokens.count - 1, maximumPrefixTokens)
        return max(0, available / batchSize * batchSize)
    }

    mutating func prepare(
        tokens: [Int32], messageEndToken: Int32?, backend: any PromptStateBackend,
        pressure: PromptCachePressure, metrics: inout Metrics,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        // Even after interruption or a partially failed restore, start from clear
        // live memory. Only immutable, successfully saved checkpoints survive.
        do {
            try checkCancellation()
            backend.clear()
            var offset = 0
            let checkpoint = Self.checkpointCount(tokens: tokens, messageEndToken: messageEndToken)
            if pressure.isDisabled {
                removeAll(); metrics.outcome = "memoryPressure"
            } else if byteLimit == 0 {
                removeAll(); metrics.outcome = "disabled"
            } else if !backend.canCapture(bytes: 0) {
                removeAll(); metrics.outcome = "lowHeadroom"
            } else if let cached = entry {
                if cached.contextID != backend.contextID {
                    removeAll(); metrics.outcome = "contextChanged"
                } else if cached.tokens.count >= tokens.count || !tokens.starts(with: cached.tokens) {
                    removeAll(); metrics.outcome = "prefixChanged"
                } else {
                    let start = ContinuousClock().now
                    let restored = cached.state.withUnsafeBytes { backend.restore(from: $0) }
                    backend.synchronize()
                    metrics.restoreSeconds = InferenceClock.seconds(since: start)
                    if restored == cached.state.count {
                        offset = cached.tokens.count
                        metrics.reusedTokens = offset
                        metrics.outcome = "hit"
                    } else {
                        removeAll(); backend.clear(); metrics.outcome = "restoreFailed"
                    }
                }
            }
            while offset < tokens.count {
                try checkCancellation()
                if pressure.isDisabled { removeAll() }
                let end = min(offset + Self.batchSize, tokens.count)
                let start = ContinuousClock().now
                try backend.decode(tokens[offset..<end])
                // GPU work must finish before phase timing or copying native state.
                if end == tokens.count || (end == checkpoint && byteLimit > 0 && !pressure.isDisabled) {
                    backend.synchronize()
                }
                metrics.decodeSeconds += InferenceClock.seconds(since: start)
                metrics.decodedTokens += end - offset
                offset = end
                try checkCancellation()
                if offset == checkpoint, checkpoint > 0, byteLimit > 0, !pressure.isDisabled {
                    let captureStart = ContinuousClock().now
                    let size = backend.stateSize()
                    let tokenBytes = checkpoint * MemoryLayout<Int32>.stride
                    if size > 0, size <= byteLimit - tokenBytes {
                        guard backend.canCapture(bytes: size + tokenBytes) else {
                            metrics.capture = "lowHeadroom"
                            metrics.captureSeconds += InferenceClock.seconds(since: captureStart)
                            continue
                        }
                        // Release the old allocation BEFORE allocating its replacement.
                        removeAll()
                        var state = Data(count: size)
                        let written = state.withUnsafeMutableBytes { backend.save(into: $0) }
                        try checkCancellation()
                        if written == size, !pressure.isDisabled {
                            entry = Entry(contextID: backend.contextID, tokens: Array(tokens.prefix(checkpoint)), state: state)
                            metrics.capture = "saved"
                        } else { metrics.capture = "failed" }
                    } else { metrics.capture = "overBudget" }
                    metrics.captureSeconds += InferenceClock.seconds(since: captureStart)
                }
            }
            if pressure.isDisabled { removeAll(); metrics.capture = "memoryPressure" }
            metrics.retainedBytes = retainedBytes
        } catch {
            // Failure/cancellation cannot leave a partially processed context or
            // checkpoint available to a later request.
            removeAll(); backend.clear(); metrics.retainedBytes = 0
            throw error
        }
    }
}
