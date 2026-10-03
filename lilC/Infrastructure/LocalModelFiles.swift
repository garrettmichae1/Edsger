import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit

/// Disk-only optional weights. Hashing and installation never run on the UI actor.
actor LocalModelFiles: ModelFileManaging {
    private let directory: URL
    private var verified = false
    private var installedURL: URL { directory.appendingPathComponent(MiniModelAsset.filename) }

    init(directory: URL = MiniModelAsset.directory) { self.directory = directory }

    func isInstalled() -> Bool { FileManager.default.fileExists(atPath: installedURL.path) }

    func verify() throws {
        guard isInstalled() else { throw ChatModelError.missing }
        guard !verified else { return }
        try Self.verifyFile(installedURL)
        verified = true
    }

    static func verifyFile(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == MiniModelAsset.byteCount else {
            throw ChatModelError.invalidDownload
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw ChatModelError.invalidDownload }
        try file.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == MiniModelAsset.sha256 else {
            throw ChatModelError.invalidDownload
        }
    }

    func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let capacity = try fm.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
        if let capacity, capacity.int64Value < MiniModelAsset.byteCount * 2 {
            throw ChatModelError.insufficientSpace
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = ModelDownloadProgress(onProgress: onProgress)
        let (temporary, response) = try await session.download(from: MiniModelAsset.downloadURL, delegate: delegate)
        defer { try? fm.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ChatModelError.invalidDownload
        }
        // Progress 1 means downloaded; UI shows "Verifying…" until install completes.
        onProgress(1)
        try Self.verifyFile(temporary)
        try Task.checkCancellation()
        // Same-volume move publishes only a complete, verified artifact. Never load partial files.
        guard !fm.fileExists(atPath: installedURL.path) else { throw ChatModelError.busy }
        try fm.moveItem(at: temporary, to: installedURL)
        var installed = installedURL
        do { try installed.setResourceValues(values) }
        catch { try? fm.removeItem(at: installedURL); throw error }
        verified = true
    }

    func remove() throws {
        if isInstalled() { try FileManager.default.removeItem(at: installedURL) }
        verified = false
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > MiniModelAsset.byteCount { downloadTask.cancel(); return }
        onProgress(min(1, Double(totalBytesWritten) / Double(MiniModelAsset.byteCount)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
