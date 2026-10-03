import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct ChatFilesSheet: View {
    let selectedID: UUID?
    let select: (ChatDocumentReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var files: [ChatDocumentReference] = []
    @State private var search = ""
    @State private var showsImporter = false
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var error: String?
    @State private var deleting: ChatDocumentReference?
    private var background: Color { scheme == .dark ? Color(white: 0.07) : .white }
    private var filtered: [ChatDocumentReference] {
        search.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) }
    }
    private var types: [UTType] {
        [.plainText, .pdf] + ["md", "markdown", "docx"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2).frame(width: 44, height: 44).background(.thinMaterial, in: Circle()) }
                    .accessibilityLabel("Close files")
                Spacer()
                Text("Add files").font(.title3.bold())
                Spacer()
                Menu {
                    Text("TXT · Markdown · PDF · DOCX")
                    Text("10 MB · 25 PDF pages · 50,000 characters")
                    Text("One file per message")
                } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44).background(.thinMaterial, in: Circle()) }
                    .accessibilityLabel("File limits")
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 18)
            Button { showsImporter = true } label: {
                HStack(spacing: 18) {
                    Image(systemName: "arrow.up.to.line").font(.title2)
                    Text("Upload files").font(.title3.weight(.semibold))
                    Spacer()
                }.padding(.horizontal, 24).frame(minHeight: 64)
            }
            .disabled(importing).accessibilityIdentifier("edsger-upload-file")
            Divider().padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Recent").font(.title2.bold())
                    if importing {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reading your file…").font(.subheadline)
                            Spacer()
                            Button("Cancel") { importTask?.cancel() }
                        }
                    }
                    if let error {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("edsger-file-error")
                    }
                    if files.isEmpty && !importing {
                        ContentUnavailableView("Your files, on this device", systemImage: "doc", description: Text("Upload a document to ask questions about it. It will appear here for reuse."))
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                            ForEach(filtered) { file in
                                Button { choose(file) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ZStack(alignment: .topTrailing) {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Image(systemName: file.kind == "pdf" ? "doc.richtext" : "doc.text").font(.title2).foregroundStyle(.secondary)
                                                Text(file.preview).font(.system(size: 12)).lineLimit(9).multilineTextAlignment(.leading)
                                                Spacer(minLength: 0)
                                            }
                                            .padding(16).frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180, alignment: .topLeading)
                                            .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.98), in: RoundedRectangle(cornerRadius: 24))
                                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.08)))
                                            Image(systemName: file.id == selectedID ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(file.id == selectedID ? Color.blue : Color.secondary)
                                                .padding(12)
                                        }
                                        Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(file.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityLabel("Attach \(file.name)")
                                .contextMenu {
                                    Button("Attach", systemImage: "paperclip") { choose(file) }
                                    Button("Delete file", systemImage: "trash", role: .destructive) { deleting = file }
                                }
                            }
                        }
                    }
                }.padding(20)
            }
        }
        .background(background).foregroundStyle(.primary).buttonStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("edsger-file-search")
            }
            .font(.title3).padding(16).background(.regularMaterial, in: Capsule()).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .presentationCornerRadius(32)
        .presentationDragIndicator(.hidden)
        .task { await refresh() }
        .onDisappear { importTask?.cancel() }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: types, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { startImport(url) }
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
        }
        .confirmationDialog("Delete this file?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { file in
            Button("Delete file", role: .destructive) {
                Task {
                    do { try await ChatDocumentStore.shared.remove(file.id); await refresh() }
                    catch { self.error = error.localizedDescription }
                    deleting = nil
                }
            }
        } message: { _ in Text("Saved answers stay in your chats. To ask new questions about this file, you'll need to import it again.") }
    }
    private func refresh() async { files = await ChatDocumentStore.shared.recent() }
    private func choose(_ file: ChatDocumentReference) { guard !importing else { return }; select(file); dismiss() }
    private func startImport(_ url: URL) {
        importing = true; error = nil
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                let ref = try await ChatDocumentStore.shared.importFile(url)
                try Task.checkCancellation()
                await refresh()
                select(ref); dismiss()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ChatDocumentChip: View {
    let document: ChatDocumentReference
    var remove: (() -> Void)?
    @State private var showsPreview = false
    var body: some View {
        HStack(spacing: 10) {
            Button { showsPreview = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(document.kind.uppercased() + (document.pageCount.map { " · \($0) pages" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityLabel("Open \(document.name)")
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .accessibilityLabel("Remove attachment")
            }
        }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .buttonStyle(.plain)
            .sheet(isPresented: $showsPreview) { ChatDocumentPreview(document: document) }
    }
}

/// The composer shows one compact file control, for pending and active document context.
struct ChatDocumentContextPill: View {
    let document: ChatDocumentReference
    let isResponding: Bool
    let clear: () -> Void
    @State private var showsPreview = false

    var body: some View {
        HStack(spacing: 0) {
            Button { showsPreview = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").accessibilityHidden(true)
                    Text(document.name).lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Preview \(document.name)")
            .accessibilityIdentifier("edsger-document-preview")
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Stop using document")
            .accessibilityHint(isResponding ? "Stops the response and clears the file for future messages." : "Returns future messages to ordinary chat. The file and earlier answers are kept.")
            .accessibilityIdentifier("edsger-clear-document-context")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08)))
        .buttonStyle(.plain)
        .accessibilityIdentifier("edsger-document-context")
        .sheet(isPresented: $showsPreview) { ChatDocumentPreview(document: document) }
    }
}

private struct ChatDocumentPreview: View {
    let document: ChatDocumentReference
    @Environment(\.dismiss) private var dismiss
    @State private var extracted: ExtractedDocument?
    @State private var error: String?
    @State private var original: URL?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(document.note).font(.footnote).foregroundStyle(.secondary)
                    Button("Open original file", systemImage: "doc") {
                        Task {
                            do { original = try await ChatDocumentStore.shared.originalURL(document.id) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if let extracted {
                        ForEach(Array(extracted.sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.location).font(.caption).foregroundStyle(.secondary)
                                Text(section.text).textSelection(.enabled)
                            }
                        }
                    } else if error == nil { ProgressView() }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(document.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .quickLookPreview($original)
            .task {
                do { extracted = try await ChatDocumentStore.shared.read(document.id) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct ChatDocumentSources: View {
    let sources: [ChatDocumentSource]
    @State private var selected: ChatDocumentSource?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answers use selected passages").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(sources) { source in
                        Button { selected = source } label: {
                            Text("[\(source.id)] \(source.location)").font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 9).background(.thinMaterial, in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("Source \(source.id), \(source.name), \(source.location)")
                    }
                }
            }
        }
        .sheet(item: $selected) { source in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(source.name).font(.headline)
                        Text(source.location).font(.subheadline).foregroundStyle(.secondary)
                        Text(source.text).textSelection(.enabled)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Source [\(source.id)]").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
            }
        }
    }
}
