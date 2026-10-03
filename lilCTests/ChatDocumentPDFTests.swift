import Foundation
import Testing
import UIKit
@testable import lilC

/// Native PDFKit extraction coverage. Run in Xcode; the Linux suite covers text/DOCX/routing.
@Suite @MainActor struct ChatDocumentPDFTests {
    @Test func textPagesAndExactPageLimit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatDocumentStore(root: root.appendingPathComponent("library"))
        let url = root.appendingPathComponent("report.pdf")
        try pdf(pages: 25, text: true).write(to: url)
        let reference = try await store.importFile(url)
        #expect(reference.pageCount == 25)
        let document = try await store.read(reference.id)
        #expect(document.sections.count == 25)
        #expect(document.sections.last?.location == "Page 25")
        #expect(document.sections.last?.text.contains("Renewal deadline: March 17") == true)
        let sources = DocumentRetrieval.sources(document: document, question: "renewal deadline")
        #expect(sources.contains { $0.text.contains("March 17") })
    }

    @Test func rejectScansTooManyPagesAndInvalidPDF() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatDocumentStore(root: root.appendingPathComponent("library"))
        for (name, data) in [("scan.pdf", pdf(pages: 1, text: false)),
                             ("long.pdf", pdf(pages: 26, text: true)),
                             ("invalid.pdf", Data("not a PDF".utf8))] {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            var rejected = false
            do { _ = try await store.importFile(url) } catch { rejected = true }
            #expect(rejected)
        }
        #expect(await store.recent().isEmpty)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func pdf(pages: Int, text: Bool) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        return renderer.pdfData { context in
            for index in 1...pages {
                context.beginPage()
                if text {
                    ("Report page \(index). Renewal deadline: March 17." as NSString)
                        .draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                } else {
                    // Visible marks with no text layer simulate image-only input.
                    context.cgContext.setFillColor(UIColor.black.cgColor)
                    context.cgContext.fill(CGRect(x: 30, y: 40, width: 100, height: 30))
                }
            }
        }
    }
}
