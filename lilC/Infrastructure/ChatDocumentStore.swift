import Foundation
import ZIPFoundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Owns only app-local, UUID-named files. Extraction never runs on the main actor.
actor ChatDocumentStore: ChatDocumentReading {
    static let shared = ChatDocumentStore()
    private let root: URL
    private var catalog: [ChatDocumentReference]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lilC/ChatDocuments", isDirectory: true)
        let url = self.root.appendingPathComponent("catalog.json")
        let data = try? Data(contentsOf: url)
        catalog = data.flatMap { try? JSONDecoder().decode([ChatDocumentReference].self, from: $0) } ?? []
    }

    func recent() -> [ChatDocumentReference] { catalog.sorted { $0.importedAt > $1.importedAt } }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func originalURL(_ id: UUID) throws -> URL {
        guard let ref = catalog.first(where: { $0.id == id }) else { throw DocumentError.missing }
        let url = folder(id).appendingPathComponent("original." + ref.kind)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DocumentError.missing }
        return url
    }
    func read(_ id: UUID) throws -> ExtractedDocument {
        try Task.checkCancellation()
        guard catalog.contains(where: { $0.id == id }),
              let data = try? Data(contentsOf: folder(id).appendingPathComponent("text.json")),
              let document = try? JSONDecoder().decode(ExtractedDocument.self, from: data),
              document.reference.id == id else { throw DocumentError.missing }
        return document
    }

    func remove(_ id: UUID) throws {
        let previous = catalog
        catalog.removeAll { $0.id == id }
        do { try saveCatalog() } catch { catalog = previous; throw error }
        // The catalog no longer exposes this directory even if cleanup fails.
        try? FileManager.default.removeItem(at: folder(id))
    }

    func importFile(_ url: URL) throws -> ChatDocumentReference {
        let budget = DocumentImportBudget()
        try budget.check()
        let kind = url.pathExtension.lowercased()
        guard DocumentLimits.extensions.contains(kind) else { throw DocumentError.unsupported }
        guard catalog.count < DocumentLimits.libraryFiles else { throw DocumentError.libraryFull }
        #if canImport(Darwin)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #endif
        var bytes: Data?
        var readError: Error?
        // Read into a bounded app-owned snapshot before parsing or persisting.
        func readSnapshot(_ coordinatedURL: URL) {
            do {
                try budget.check()
                let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw DocumentError.unreadable }
                guard let size = values.fileSize, size <= DocumentLimits.fileBytes else { throw DocumentError.tooLarge }
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                var snapshot = Data()
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    try budget.check()
                    guard snapshot.count + chunk.count <= DocumentLimits.fileBytes else { throw DocumentError.tooLarge }
                    snapshot.append(chunk)
                }
                bytes = snapshot
            } catch { readError = error }
        }
        #if canImport(Darwin)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: readSnapshot)
        if let coordinationError { throw coordinationError }
        #else
        readSnapshot(url)
        #endif
        if let readError { throw readError }
        guard let bytes else { throw DocumentError.unreadable }
        try budget.check()
        guard catalog.reduce(0, { $0 + $1.byteCount }) + bytes.count <= DocumentLimits.libraryBytes else { throw DocumentError.libraryFull }
        let id = UUID()
        let directory = folder(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        let original = directory.appendingPathComponent("original." + kind)
        try write(bytes, to: original)
        let sections: [DocumentSection]
        let pageCount: Int?
        let note: String
        switch kind {
        case "txt", "md", "markdown":
            let text = try DocumentText.decode(bytes)
            // Block references don't imply Word/PDF pagination.
            sections = text.components(separatedBy: "\n\n").enumerated().filter { !$0.element.isEmpty }
                .map { .init(location: "Paragraph \($0.offset + 1)", text: $0.element) }
            pageCount = nil
            note = "Plain text; Markdown images and links are not fetched."
        case "docx":
            let text = try Self.readWord(original, budget: budget)
            sections = text.components(separatedBy: "\n").enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { .init(location: "Paragraph \($0.offset + 1)", text: $0.element) }
            pageCount = nil
            note = "Main document text and table cell text only. Formatting, pictures, headers, footnotes and visual layout aren't analyzed. Deleted tracked text is excluded."
        case "pdf":
            #if canImport(PDFKit)
            guard let pdf = PDFDocument(url: original), !pdf.isLocked else { throw DocumentError.unreadable }
            guard pdf.pageCount > 0, pdf.pageCount <= DocumentLimits.pdfPages else { throw DocumentError.tooLong }
            var pages: [DocumentSection] = []
            var total = 0
            for index in 0..<pdf.pageCount {
                try budget.check()
                guard let page = pdf.page(at: index), let raw = page.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.scannedPDF }
                let text = try DocumentText.clean(raw)
                total += text.count
                guard total <= DocumentLimits.characters else { throw DocumentError.tooLong }
                pages.append(.init(location: "Page \(index + 1)", text: text))
            }
            sections = pages; pageCount = pdf.pageCount
            note = "Extracted page text only. Images, charts, equation layout and complex reading order aren't analyzed."
            #else
            throw DocumentError.unsupported
            #endif
        default: throw DocumentError.unsupported
        }
        try budget.check()
        let count = sections.reduce(0) { $0 + $1.text.count }
        guard count > 0, count <= DocumentLimits.characters else { throw DocumentError.tooLong }
        let rawName = url.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(rawName)).prefix(160)
        let ref = ChatDocumentReference(id: id, name: String(name), kind: kind, byteCount: bytes.count,
            characterCount: count, pageCount: pageCount, preview: String(sections.map(\.text).joined(separator: "\n").prefix(400)),
            importedAt: Date(), note: note)
        let document = ExtractedDocument(reference: ref, sections: sections)
        try write(JSONEncoder().encode(document), to: directory.appendingPathComponent("text.json"))
        try budget.check()
        catalog.append(ref)
        do { try saveCatalog() } catch { catalog.removeAll { $0.id == id }; throw error }
        committed = true
        return ref
    }

    private static func readWord(_ url: URL, budget: DocumentImportBudget) throws -> String {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw DocumentError.unreadable }
        var entries = 0
        var expanded: UInt64 = 0
        var paths = Set<String>()
        for entry in archive {
            try budget.check()
            guard entry.uncompressedSize <= 50 * 1024 * 1024 else { throw DocumentError.complexWord }
            guard paths.insert(entry.path).inserted else { throw DocumentError.unreadable }
            entries += 1; expanded += entry.uncompressedSize
            guard entries <= 2_000, expanded <= 50 * 1024 * 1024 else { throw DocumentError.complexWord }
        }
        guard let entry = archive["word/document.xml"], entry.type == .file else { throw DocumentError.unreadable }
        guard entry.uncompressedSize <= DocumentLimits.xmlBytes else { throw DocumentError.complexWord }
        var xml = Data()
        let crc = try archive.extract(entry, bufferSize: 16_384) { chunk in
            try budget.check()
            guard xml.count + chunk.count <= DocumentLimits.xmlBytes else { throw DocumentError.complexWord }
            xml.append(chunk)
        }
        guard crc == entry.checksum else { throw DocumentError.unreadable }
        return try WordDocumentText.extract(xml)
    }

    private func saveCatalog() throws { try write(JSONEncoder().encode(catalog), to: root.appendingPathComponent("catalog.json")) }
    private func write(_ data: Data, to url: URL) throws {
        #if canImport(Darwin)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
