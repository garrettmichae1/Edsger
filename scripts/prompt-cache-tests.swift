import Foundation

private func require(_ condition: Bool, _ message: String = "Regression failed") { precondition(condition, message) }

private final class MemoryBackend: PromptStateBackend {
    var contextID = UUID()
    var live: [Int32] = []
    var batches: [Int] = []
    var restores = 0
    var saves = 0
    var clears = 0
    var failRestore = false
    var failSave = false
    var failBatch: Int?
    var oversized = false
    var captureAllowed = true
    var onSave: (() -> Void)?
    enum Failure: Error { case decode }
    func clear() { clears += 1; live = []; batches = [] }
    func decode(_ tokens: ArraySlice<Int32>) throws {
        if batches.count + 1 == failBatch { throw Failure.decode }
        batches.append(tokens.count); live += tokens
    }
    func data() -> Data { try! JSONEncoder().encode(live) }
    func synchronize() {}
    func canCapture(bytes: Int) -> Bool { captureAllowed }
    func stateSize() -> Int { oversized ? Int.max : data().count }
    func save(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        saves += 1; onSave?()
        if failSave { return 0 }
        let bytes = data()
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        return bytes.count
    }
    func restore(from buffer: UnsafeRawBufferPointer) -> Int {
        restores += 1
        if failRestore { live = [-999]; return 0 }
        live = try! JSONDecoder().decode([Int32].self, from: Data(buffer))
        return buffer.count
    }
}

@main struct PromptCacheTests {
    static func main() throws {
        let marker: Int32 = -1
        let tokens = (0..<698).map(Int32.init) + [marker, -2]
        func prepare(_ cache: inout PromptReuseCache, _ backend: MemoryBackend,
                     _ input: [Int32] = tokens, _ pressure: PromptCachePressure = .init()) throws -> PromptReuseCache.Metrics {
            var metrics = PromptReuseCache.Metrics()
            try cache.prepare(tokens: input, messageEndToken: marker, backend: backend,
                              pressure: pressure, metrics: &metrics)
            require(backend.live == input, "Cached and full processing must see the same tokens")
            require(metrics.decodedTokens + metrics.reusedTokens == input.count)
            require(metrics.retainedBytes <= cache.byteLimit)
            return metrics
        }
        var cases = 0
        func passed(_ label: String) { cases += 1; print("PASS \(label)") }

        var cache = PromptReuseCache(byteLimit: 16_384)
        let backend = MemoryBackend()
        let cold = try prepare(&cache, backend)
        require(cold.reusedTokens == 0 && cold.capture == "saved")
        require(backend.batches == [256, 256, 188])
        backend.live += [9000, 9001] // Generation must not modify the saved prompt.
        let hit = try prepare(&cache, backend)
        require(hit.outcome == "hit" && hit.reusedTokens == 512)
        require(backend.batches == [188] && backend.saves == 1)
        passed("exact prefix survives generation; fresh suffix; no redundant capture")

        var suffix = tokens; suffix[600] = 12345
        require(try prepare(&cache, backend, suffix).reusedTokens == 512)
        passed("changed contents after checkpoint are decoded freshly")

        var changed = tokens; changed[5] = 999
        require(try prepare(&cache, backend, changed).outcome == "prefixChanged")
        passed("changed file/project prefix falls back")

        let shorter = Array(changed.prefix(298)) + [marker, -2]
        require(try prepare(&cache, backend, shorter).reusedTokens == 0)
        passed("truncated history falls back")

        _ = try prepare(&cache, backend)
        backend.contextID = UUID()
        require(try prepare(&cache, backend).outcome == "contextChanged")
        passed("model/context replacement invalidates checkpoint")

        backend.failRestore = true
        let failedRestore = try prepare(&cache, backend)
        require(failedRestore.outcome == "restoreFailed" && failedRestore.reusedTokens == 0)
        backend.failRestore = false
        passed("partial restore failure clears live state and decodes everything")

        cache.removeAll(); backend.failSave = true
        require(try prepare(&cache, backend).capture == "failed")
        require(cache.retainedBytes == 0)
        backend.failSave = false
        passed("failed capture is never published")

        backend.oversized = true
        let savesBefore = backend.saves
        require(try prepare(&cache, backend).capture == "overBudget")
        require(backend.saves == savesBefore && cache.retainedBytes == 0)
        backend.oversized = false
        passed("oversized native state rejected before allocation")

        _ = try prepare(&cache, backend)
        backend.captureAllowed = false
        let lowMemory = try prepare(&cache, backend)
        require(lowMemory.outcome == "lowHeadroom" && lowMemory.capture == "lowHeadroom")
        require(cache.retainedBytes == 0)
        backend.captureAllowed = true
        require(try prepare(&cache, backend).capture == "saved")
        passed("low headroom evicts and skips allocation; recovery can capture again")

        var disabled = PromptReuseCache(byteLimit: 0)
        require(try prepare(&disabled, backend).outcome == "disabled")
        passed("disabled baseline uses unchanged full batches")

        let pressure = PromptCachePressure()
        _ = try prepare(&cache, backend)
        pressure.disable()
        require(try prepare(&cache, backend, tokens, pressure).outcome == "memoryPressure")
        require(cache.retainedBytes == 0)
        passed("memory warning evicts and prevents recapture")

        let duringSave = PromptCachePressure()
        backend.onSave = { duringSave.disable() }
        _ = try prepare(&cache, backend, tokens, duringSave)
        require(cache.retainedBytes == 0)
        backend.onSave = nil
        passed("warning during capture does not publish state")

        var cancelled = false
        backend.onSave = { cancelled = true }
        var metrics = PromptReuseCache.Metrics()
        do {
            try cache.prepare(tokens: tokens, messageEndToken: marker, backend: backend,
                              pressure: .init(), metrics: &metrics) {
                if cancelled { throw CancellationError() }
            }
            preconditionFailure("Expected cancellation")
        } catch is CancellationError {}
        require(cache.retainedBytes == 0 && backend.live.isEmpty)
        backend.onSave = nil
        passed("cancellation during capture clears state")

        var checks = 0
        do {
            try cache.prepare(tokens: tokens, messageEndToken: marker, backend: backend,
                              pressure: .init(), metrics: &metrics) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
            preconditionFailure("Expected cancellation")
        } catch is CancellationError {}
        require(cache.retainedBytes == 0 && backend.live.isEmpty)
        passed("cancellation during prefill clears state")

        backend.failBatch = 3
        do { _ = try prepare(&cache, backend); preconditionFailure("Expected decode failure") }
        catch MemoryBackend.Failure.decode {}
        require(cache.retainedBytes == 0 && backend.live.isEmpty)
        backend.failBatch = nil
        _ = try prepare(&cache, backend)
        passed("decode failure after capture clears state; next request recovers")

        require(PromptReuseCache.checkpointCount(tokens: [marker, 3], messageEndToken: marker) == 0)
        require(PromptReuseCache.checkpointCount(tokens: tokens, messageEndToken: nil) == 0)
        require(PromptReuseCache.checkpointCount(tokens: tokens, messageEndToken: -999) == 0)
        let long = Array(repeating: Int32(1), count: 4096) + [marker, -2]
        require(PromptReuseCache.checkpointCount(tokens: long, messageEndToken: marker) == 1024)
        passed("boundary detection requires a complete message and obeys cap")

        // Alternating inference modes is a miss, never a cross-mode answer cache.
        var otherMode = tokens; otherMode[0] = -45
        _ = try prepare(&cache, backend, otherMode)
        require(try prepare(&cache, backend).reusedTokens == 0)
        passed("mode switch safely evicts the single entry")
        print("\(cases) cache regression cases passed")
    }
}
