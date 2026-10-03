import Foundation
import CryptoKit

/// Read-only bundled weights. Integrity checks never run on the UI actor.
actor LocalModelFiles: ModelFileManaging {
    private let modelURL: URL?
    private let legacyDownloadURL: URL?
    private var verified = false

    init(modelURL: URL? = MiniModelAsset.bundledURL(),
         legacyDownloadURL: URL? = MiniModelAsset.legacyDownloadURL) {
        self.modelURL = modelURL
        self.legacyDownloadURL = legacyDownloadURL
    }

    func isInstalled() -> Bool {
        guard let modelURL else { return false }
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    func verify() throws {
        guard let modelURL, isInstalled() else { throw ChatModelError.missing }
        guard !verified else { return }
        try Self.verifyFile(modelURL)
        verified = true
        // Upgrades keep the saved choice. Reclaim the old duplicate only after
        // verifying its bundled replacement; never remove the bundle or a folder.
        if let legacyDownloadURL, legacyDownloadURL.standardizedFileURL != modelURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: legacyDownloadURL)
        }
    }

    static func verifyFile(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == MiniModelAsset.byteCount else {
            throw ChatModelError.invalidAsset
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw ChatModelError.invalidAsset }
        try file.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == MiniModelAsset.sha256 else {
            throw ChatModelError.invalidAsset
        }
    }
}
