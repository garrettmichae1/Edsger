import SwiftUI

/// Shared by text chat and the IDE. Only explicit sends/jumps override a reading position.
struct ConversationTranscript<Content: View>: View {
    let conversationID: UUID?
    let revision: Int
    let sentMessageID: UUID?
    @ViewBuilder let content: () -> Content
    @State private var scrollState = TranscriptScrollState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct GeometrySnapshot: Equatable {
        let distanceFromBottom: Double
        let contentHeight: Double
        let viewportHeight: Double
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: GeometrySnapshot.self) { geometry in
                GeometrySnapshot(
                    distanceFromBottom: Double(geometry.contentSize.height + geometry.contentInsets.bottom
                                               - geometry.contentOffset.y - geometry.containerSize.height),
                    contentHeight: Double(geometry.contentSize.height),
                    viewportHeight: Double(geometry.containerSize.height))
            } action: { old, new in
                scrollState.updateDistanceFromBottom(new.distanceFromBottom)
                if old.contentHeight != new.contentHeight {
                    if scrollState.contentChanged() { reader.scrollTo("transcript-bottom", anchor: .bottom) }
                } else if old.viewportHeight != new.viewportHeight, scrollState.shouldFollow {
                    reader.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: scrollState.beginInteraction()
                case .idle: scrollState.endInteraction()
                case .animating: break
                @unknown default: break
                }
            }
            .onChange(of: revision) { _, _ in
                if scrollState.contentChanged() { reader.scrollTo("transcript-bottom", anchor: .bottom) }
            }
            .onChange(of: sentMessageID) { _, _ in
                scrollState.showLatest()
                reader.scrollTo("transcript-bottom", anchor: .bottom)
            }
            .task(id: conversationID) {
                scrollState = TranscriptScrollState()
                reader.scrollTo("transcript-bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !scrollState.followsLatest && !scrollState.isNearBottom {
                    Button {
                        scrollState.showLatest()
                        if reduceMotion { reader.scrollTo("transcript-bottom", anchor: .bottom) }
                        else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                reader.scrollTo("transcript-bottom", anchor: .bottom)
                            }
                        }
                    } label: {
                        Label(scrollState.hasUnreadContent ? "New content" : "Latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to the latest message")
                    .padding(12)
                }
            }
        }
    }
}

struct EdsgerScreen: View {
    @Bindable var session: TutorSession
    let openHome: () -> Void
    let openSettings: () -> Void
    let openFiles: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showsHistory = false
    @State private var showsChatFiles = false
    @State private var models = ChatModelStore.shared
    @State private var historySearch = ""
    @State private var pendingDelete: TutorConversation?
    @State private var studyTopics = Array(Self.studySubjects.shuffled().prefix(5))
    private static let studySubjects = [
        "C", "Python", "JavaScript", "Lua", "Physics", "Mathematics",
        "Algebra", "Linear Algebra", "Calculus", "Statistics", "Probability",
        "Geometry", "Trigonometry", "Discrete Mathematics", "Differential Equations",
        "Data Structures", "Algorithms", "Operating Systems", "Databases",
        "Computer Architecture", "Compilers", "Computer Networks", "Cybersecurity",
        "Software Engineering", "Web Development", "Machine Learning",
        "Artificial Intelligence", "Java", "Swift", "C++", "Rust", "SQL",
        "HTML and CSS", "Git", "Chemistry", "Biology", "Astronomy",
        "Earth Science", "Environmental Science", "Neuroscience", "Psychology",
        "Philosophy", "Logic", "Economics", "World History", "Political Science",
        "Sociology", "Literature", "Creative Writing", "Music Theory"
    ]
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }
    private var selection: Color { scheme == .dark ? Color(white: 0.19) : Color(white: 0.93) }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
        }
        .background(background)
        .foregroundStyle(Color.primary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .sheet(isPresented: $showsHistory) { history }
        .sheet(isPresented: $showsChatFiles) {
            ChatFilesSheet(selectedID: session.pendingDocument?.id) { session.attach($0) }
        }
        .task { await models.refresh() }
        .onAppear { refreshStudyTopics() }
        .onChange(of: session.selectedID) { _, _ in refreshStudyTopics() }
        .onDisappear { session.stop(); session.flushDrafts() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { composerFocused = false; showsHistory = true } label: {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: 15, height: 2.5)
                        Capsule().frame(width: 21, height: 2.5)
                    }
                    Circle().fill(Color.blue).frame(width: 9, height: 9).offset(x: 4, y: -3)
                }
                .frame(width: 48, height: 48)
                .background(surface, in: Circle())
            }
            .accessibilityLabel("Chat history")
            .accessibilityIdentifier("edsger-history")
            Spacer(minLength: 0)
            ChatModelPicker()
                .font(.system(size: 18, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                session.newConversation(); composerFocused = true
            } label: {
                EdsgerChatGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 29, height: 29)
                    .frame(width: 48, height: 48)
                    .background(surface, in: Circle())
            }
            .accessibilityLabel("New EDSGER chat")
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.07), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var transcript: some View {
        ConversationTranscript(conversationID: session.selectedID,
                               revision: session.transcriptRevision,
                               sentMessageID: session.messages.last(where: { $0.role == .user })?.id) {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(session.messages) { message in
                    if message.role == .user {
                        HStack {
                            Spacer(minLength: 38)
                            VStack(alignment: .leading, spacing: 10) {
                                if let document = message.document { ChatDocumentChip(document: document) }
                                Text(message.text)
                                .textSelection(.enabled)
                            }
                                .padding(.horizontal, 17).padding(.vertical, 12)
                                .background(selection, in: RoundedRectangle(cornerRadius: 24))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("EDSGER").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(1)
                            if message.text.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(session.generationStatus?.label ?? GenerationStatus.waiting.label).foregroundStyle(.secondary).font(.subheadline)
                                }
                            } else {
                                MathAnswerView(text: message.text)
                                    .textSelection(.enabled)
                                if let sources = message.sources, !sources.isEmpty { ChatDocumentSources(sources: sources) }
                                if !session.isResponding {
                                    Button { UIPasteboard.general.string = message.text } label: {
                                        Image(systemName: "doc.on.doc").font(.system(size: 15))
                                    }
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Copy answer")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error = models.errorMessage {
                    HStack(alignment: .top) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("Dismiss") { models.clearError() }.font(.caption)
                    }
                }
                if let error = session.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        if !session.messages.isEmpty { Button("Try again") { session.retry() } }
                    }
                    .font(.subheadline)
                } else if let notice = session.notice, !session.canUndoDocumentContext {
                    Text(notice).foregroundStyle(.secondary).font(.footnote)
                    if !session.messages.isEmpty { Button("Regenerate response") { session.retry() }.font(.footnote) }
                }
                if session.isResponding, session.messages.last?.text.isEmpty == false {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(session.generationStatus?.label ?? GenerationStatus.waiting.label)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 24)
            .padding(.top, 15)
            .padding(.bottom, 12)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if models.isChanging {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing model…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            if let document = session.pendingDocument ?? session.activeDocument {
                ChatDocumentContextPill(document: document, isResponding: session.isResponding,
                                        clear: { session.clearDocumentContext() })
                    .padding(.horizontal, 12)
            } else if session.canUndoDocumentContext, let notice = session.notice {
                HStack(spacing: 12) {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                    Button("Undo") { session.undoClearDocumentContext() }
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Undo clearing document context")
                        .accessibilityIdentifier("edsger-undo-document-context")
                }
                .padding(.horizontal, 12)
            }
            EdsgerComposerBar(draft: $session.draft, focused: $composerFocused,
                              isResponding: session.isResponding,
                              canSend: !models.isChanging && (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.pendingDocument != nil),
                              send: { session.send() }, stop: { session.stop() }) {
                Button("Files", systemImage: "paperclip") { composerFocused = false; showsChatFiles = true }
                Divider()
                ForEach(studyTopics, id: \.self) { topic in
                    Button("Study " + topic) {
                        session.draft = "Help me learn \(topic). Start by asking what I already know."
                        composerFocused = true
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(background)
    }

    private var filteredConversations: [TutorConversation] {
        guard !historySearch.isEmpty else { return session.conversations }
        return session.conversations.filter { chat in
            if chat.title.localizedCaseInsensitiveContains(historySearch) { return true }
            if session.draft(for: chat.id).localizedCaseInsensitiveContains(historySearch) { return true }
            if session.documentDraft(for: chat.id)?.name.localizedCaseInsensitiveContains(historySearch) == true { return true }
            return chat.messages.contains { message in
                message.text.localizedCaseInsensitiveContains(historySearch) ||
                    message.document?.name.localizedCaseInsensitiveContains(historySearch) == true
            }
        }
    }

    private func historyTitle(_ chat: TutorConversation) -> String {
        guard chat.messages.isEmpty else { return chat.title }
        let draft = session.draft(for: chat.id)
        return draft.isEmpty ? session.documentDraft(for: chat.id)?.name ?? chat.title : String(draft.prefix(70))
    }

    private var history: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your conversations")
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.8)
                        Text("Pick up where you left off.")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button { showsHistory = false; session.stop(); openHome() } label: {
                            historyShortcut("IDE", systemImage: "house")
                        }
                        Button { showsHistory = false; session.stop(); openSettings() } label: {
                            historyShortcut("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("edsger-history-settings")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(filteredConversations) { chat in
                    HStack(spacing: 0) {
                        Button {
                            session.select(chat.id); showsHistory = false
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: chat.isPinned ? "pin.fill" : "bubble.left")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(chat.isPinned ? Color.blue : Color.secondary)
                                    .frame(width: 44, height: 44)
                                    .background(chat.isPinned ? Color.blue.opacity(0.10) : selection, in: Circle())
                                VStack(alignment: .leading, spacing: 7) {
                                    if !session.draft(for: chat.id).isEmpty || session.documentDraft(for: chat.id) != nil {
                                        Label("Draft", systemImage: "pencil")
                                            .font(.caption).foregroundStyle(Color.blue)
                                    }
                                    Text(historyTitle(chat))
                                        .font(.system(size: 17, weight: .semibold))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(chat.updatedAt, style: .date)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(17)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityValue(chat.isPinned ? "Pinned" : "")
                        .accessibilityAction(named: chat.isPinned ? "Unpin chat" : "Pin chat") {
                            toggleHistoryPin(chat.id)
                        }
                        .accessibilityAction(named: "Delete chat") { pendingDelete = chat }
                        Menu {
                            ConversationHistoryActions(isPinned: chat.isPinned,
                                                       pin: { toggleHistoryPin(chat.id) },
                                                       delete: { pendingDelete = chat })
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Chat options for \(chat.title)")
                        .accessibilityIdentifier("chat-options-\(chat.id)")
                        .padding(.trailing, 8)
                    }
                    .background(surface, in: RoundedRectangle(cornerRadius: 26))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 12, y: 4)
                    .contentShape(RoundedRectangle(cornerRadius: 26))
                    .contextMenu {
                        ConversationHistoryActions(isPinned: chat.isPinned,
                                                   pin: { toggleHistoryPin(chat.id) },
                                                   delete: { pendingDelete = chat })
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = chat }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            toggleHistoryPin(chat.id)
                        } label: {
                            Label(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(Color.blue)
                    }
                }
            }
            .buttonStyle(.plain)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background)
            .foregroundStyle(Color.primary)
            .searchable(text: $historySearch, prompt: "Search your chats")
            .navigationTitle("EDSGER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsHistory = false }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .alert("Delete chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { chat in
                Button("Delete", role: .destructive) { session.delete(chat.id); pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This conversation and its draft will be permanently deleted.")
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func refreshStudyTopics() {
        studyTopics = Array(Self.studySubjects.shuffled().prefix(5))
    }

    private func toggleHistoryPin(_ id: UUID) {
        if reduceMotion { session.togglePin(id) }
        else {
            withAnimation(.easeInOut(duration: 0.2)) { session.togglePin(id) }
        }
    }

    private func historyShortcut(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(surface, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 12, y: 4)
    }

}

/// Shared by the visible options menu and long-press menu in both histories.
struct ConversationHistoryActions: View {
    let isPinned: Bool
    let pin: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin", action: pin)
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
    }
}

private struct EdsgerChatGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) * 0.43
        func point(_ degrees: Double) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        var path = Path()
        path.addArc(center: center, radius: r, startAngle: .degrees(220), endAngle: .degrees(315), clockwise: false)
        path.move(to: point(340))
        path.addArc(center: center, radius: r, startAngle: .degrees(340), endAngle: .degrees(80), clockwise: false)
        path.move(to: point(105))
        path.addLine(to: CGPoint(x: rect.minX + 7, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 10))
        path.addArc(center: center, radius: r, startAngle: .degrees(155), endAngle: .degrees(195), clockwise: false)
        return path
    }
}

/// A single row at rest; longer drafts grow to six lines before scrolling.
struct EdsgerComposerBar<Additions: View>: View {
    @Binding var draft: String
    let focused: FocusState<Bool>.Binding
    let isResponding: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void
    @ViewBuilder let additions: () -> Additions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu(content: additions) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add files or choose a study topic")
            .accessibilityIdentifier("edsger-add")

            TextField("Ask EDSGER", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .fixedSize(horizontal: false, vertical: true)
                .focused(focused)
                .accessibilityLabel("Message EDSGER")
                .accessibilityIdentifier("edsger-composer")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 2)
                .layoutPriority(1)

            Button(action: isResponding ? stop : send) {
                Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                    .font(.system(size: isResponding ? 15 : 20, weight: .semibold))
                    .foregroundStyle(isResponding || canSend ? Color.white : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(isResponding ? Color.black : (canSend ? Color.blue : Color.secondary.opacity(0.12)), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!isResponding && !canSend)
            .accessibilityLabel(isResponding ? "Stop EDSGER" : "Send to EDSGER")
            .accessibilityIdentifier("edsger-send")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .padding(6)
        .fixedSize(horizontal: false, vertical: true)
        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.985),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.09 : 0.04), lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 16, y: 4)
    }
}
