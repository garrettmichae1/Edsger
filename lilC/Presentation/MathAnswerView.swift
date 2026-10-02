import SwiftUI
import SwiftMath
import Textual

/// Shared by chat and future recognized-equation previews. No model or network dependency.
@MainActor
final class MathTypesetter {
    static let shared = MathTypesetter()
    final class Result {
        let image: UIImage?
        let descent: CGFloat
        init(image: UIImage? = nil, descent: CGFloat = 0) {
            self.image = image; self.descent = descent
        }
    }
    private let cache = NSCache<NSString, Result>()
    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func render(_ latex: String, size: CGFloat, display: Bool, dark: Bool) -> Result {
        let key = "\(size)|\(display)|\(dark)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let result = makeImage(latex, size: size, display: display, dark: dark)
        let cost = result.image.map { Int($0.size.width * $0.size.height * $0.scale * $0.scale * 4) } ?? 1
        cache.setObject(result, forKey: key, cost: cost)
        return result
    }

    private func makeImage(_ latex: String, size: CGFloat, display: Bool, dark: Bool) -> Result {
        // Bound generated input and nesting before entering the third-party parser.
        guard latex.count <= 3000, !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Result() }
        var depth = 0
        for char in latex {
            if char == "{" { depth += 1 }
            if char == "}" { depth -= 1 }
            if depth > 40 { return Result() }
        }
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.fontSize = size
        label.labelMode = display ? .display : .text
        label.latex = latex
        guard label.error == nil, label.mathList != nil else { return Result() }
        let bounds = label.intrinsicContentSize
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 4096, bounds.height <= 2048,
              bounds.width * bounds.height <= 500_000 else { return Result() }
        var formula = MathImage(latex: latex, fontSize: size, textColor: dark ? .white : .black,
                                labelMode: display ? .display : .text, textAlignment: .left)
        formula.contentInsets = MTEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let (error, image, layout) = formula.asImage()
        guard error == nil, let image, let layout else { return Result() }
        return Result(image: image, descent: layout.descent + 2)
    }
}

struct MathEquationView: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var fontSize = 21.0

    var body: some View {
        let rendered = MathTypesetter.shared.render(latex, size: fontSize, display: true, dark: scheme == .dark)
        ScrollView(.horizontal) {
            Group {
                if let image = rendered.image {
                    Image(uiImage: image).fixedSize()
                        .accessibilityLabel("Equation: " + latex)
                } else {
                    Text(verbatim: latex)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color.secondary.opacity(scheme == .dark ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            Button("Copy equation", systemImage: "doc.on.doc") { UIPasteboard.general.string = latex }
        }
        .accessibilityAction(named: "Copy equation") { UIPasteboard.general.string = latex }
    }
}

struct MathAnswerView: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var fontSize = 17.0

    var body: some View {
        let blocks = MathMessage.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let runs):
                    let content = ChatMarkdownContent(runs: runs)
                    StructuredText(content.markdown, parser: ChatMarkdownParser(equations: content.equations, fontSize: fontSize, dark: scheme == .dark))
                        .id("\(scheme)-\(fontSize)")
                        .font(.system(size: fontSize))
                        .textual.textSelection(.enabled)
                case .equation(let latex):
                    MathEquationView(latex: latex)
                case .code(let language, let source):
                    StructuredText(ChatMarkdownContent.code(language: language, source: source), parser: ChatMarkdownParser())
                        .font(.system(size: fontSize))
                        .textual.codeBlockStyle(ChatCodeBlockStyle())
                        .textual.textSelection(.enabled)

                }
            }
        }
    }

}

/// Keep SwiftMath as the sole renderer for equations, including math inside tables and lists.
struct ChatMarkdownContent {
    let markdown: String
    let equations: [String: String]

    init(runs: [MathMessage.Inline]) {
        var markdown = ""
        var equations: [String: String] = [:]
        let original = runs.map { if case .text(let value) = $0 { return value }; return "" }.joined()
        var prefix = "LILCMATHATTACHMENT"
        while original.contains(prefix) { prefix += "X" }
        for run in runs {
            switch run {
            case .text(let value): markdown += value
            case .math(let latex):
                let marker = "\(prefix)\(equations.count)END"
                equations[marker] = latex
                markdown += marker
            }
        }
        self.markdown = markdown
        self.equations = equations
    }

    static func code(language: String, source: String) -> String {
        var fence = "```"
        while source.contains(fence) { fence += "`" }
        let hint = language.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return fence + hint + "\n" + source + "\n" + fence
    }
}

struct ChatMarkdownParser: MarkupParser {
    var equations: [String: String] = [:]
    var fontSize: CGFloat = 17
    var dark = false

    func attributedString(for input: String) throws -> AttributedString {
        var result = (try? AttributedStringMarkdownParser(baseURL: nil).attributedString(for: input)) ?? AttributedString(input)
        // Model-generated image links remain alt text; rendering a reply never fetches remote media.
        for run in Array(result.runs) where run.imageURL != nil {
            result[run.range].imageURL = nil
        }
        for (marker, latex) in equations {
            if let range = result.range(of: marker) {
                let attributes = result[range].runs.first?.attributes ?? AttributeContainer()
                let rendered = MathTypesetter.shared.render(latex, size: fontSize, display: false, dark: dark)
                var replacement = AttributedString(latex, attributes: attributes)
                if let image = rendered.image, let png = image.pngData() {
                    let attachment = ChatMathAttachment(latex: latex, data: png, size: image.size, descent: rendered.descent)
                    replacement.textual.attachment = AnyAttachment(attachment)
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}

private struct ChatMathAttachment: Attachment {
    let latex: String
    let data: Data
    let size: CGSize
    let descent: CGFloat
    var description: String { "\\(" + latex + "\\)" }
    var selectionStyle: AttachmentSelectionStyle { .text }
    var body: some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image).accessibilityLabel("Equation: " + latex)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize { size }
    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat { -descent }
    func pngData() -> Data? { data }
}

private struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let language = configuration.languageHint, !language.isEmpty {
                Text(language).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                configuration.label
                    .font(.system(size: 14, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }
}
