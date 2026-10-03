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
    let openFiles: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showsHistory = false
    @State private var showsInfo = false
    @State private var showsModels = false
    @State private var models = ChatModelStore.shared
    @State private var historySearch = ""
    @State private var pendingDelete: TutorConversation?
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }
    private var selection: Color { scheme == .dark ? Color(white: 0.19) : Color(white: 0.93) }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .background(background)
        .foregroundStyle(Color.primary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !composerFocused { navigation }
        }
        .sheet(isPresented: $showsHistory) { history }
        .sheet(isPresented: $showsModels) { ChatModelPicker() }
        .task { await models.refresh() }
        .sheet(isPresented: $showsInfo) {
            EdsgerInfoSheet(background: background, surface: surface, selection: selection)
        }
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
            Button { composerFocused = false; showsModels = true } label: {
                HStack(spacing: 6) {
                    Text(models.selected == .mini ? "EDSGER mini" : "EDSGER")
                        .font(.system(size: 18, weight: .semibold))
                        .accessibilityIdentifier("edsger-title")
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Chat model: " + models.selected.title)
            .accessibilityHint("Choose or download a model")
            .accessibilityIdentifier("edsger-model-picker")
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
                            Text(message.text)
                                .textSelection(.enabled)
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
                } else if let notice = session.notice {
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
        VStack(alignment: .leading, spacing: 15) {
            if models.isChanging {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing model…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if session.messages.isEmpty {
                HStack(spacing: 13) {
                    Text("📚").font(.system(size: 23))
                    Text("What would you like to learn?")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 8)
                .accessibilityLabel("Ask EDSGER about coding or any academic subject")
            }
            VStack(alignment: .leading, spacing: 16) {
                TextField("Ask EDSGER", text: $session.draft, prompt: Text("Ask EDSGER").fontWeight(.semibold).foregroundStyle(.secondary), axis: .vertical)
                    .font(.system(size: 21))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .accessibilityIdentifier("edsger-composer")
                    .padding(.horizontal, 4)
                HStack {
                    Menu {
                        ForEach(["C", "Python", "JavaScript", "Lua", "History", "Physics", "Mathematics"], id: \.self) { topic in
                            Button("Study " + topic) {
                                session.draft = "Help me learn \(topic). Start by asking what I already know."
                                composerFocused = true
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 28, weight: .regular)).frame(width: 36, height: 40)
                    }
                    .accessibilityLabel("Choose a study topic")
                    Spacer()
                    Button { composerFocused = false; showsHistory = true } label: {
                        ZStack {
                            Circle().trim(from: 0.10, to: 0.90).stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(90)).frame(width: 27, height: 27)
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).offset(x: 2, y: 2)
                        }.frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Search chats")
                    Button {
                        if session.isResponding { session.stop() }
                        else { session.send() }
                    } label: {
                        Image(systemName: session.isResponding ? "stop.fill" : "arrow.up")
                            .font(.system(size: session.isResponding ? 18 : 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue.opacity(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isResponding ? 0.45 : 1), in: Circle())
                    }
                    .disabled(!session.isResponding && (models.isChanging || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityLabel(session.isResponding ? "Stop EDSGER" : "Send to EDSGER")
                    .accessibilityIdentifier("edsger-send")
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(surface, in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.09), radius: 22, y: 8)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var navigation: some View {
        HStack {
            Button { session.stop(); openHome() } label: { Label("IDE", systemImage: "house") }
            Spacer()
            Text("EDSGER · Offline").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button { showsInfo = true } label: { Label("Info", systemImage: "info.circle") }
                .accessibilityLabel("How lilC works offline")
                .accessibilityIdentifier("edsger-info")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(background)
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
                    Button { showsHistory = false; session.stop(); openHome() } label: {
                        historyShortcut("IDE", systemImage: "house")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(session.conversations.filter { historySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(historySearch) || session.draft(for: $0.id).localizedCaseInsensitiveContains(historySearch) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(historySearch) } }) { chat in
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
                                    if !session.draft(for: chat.id).isEmpty {
                                        Label("Draft", systemImage: "pencil")
                                            .font(.caption).foregroundStyle(Color.blue)
                                    }
                                    Text(chat.messages.isEmpty && !session.draft(for: chat.id).isEmpty
                                         ? String(session.draft(for: chat.id).prefix(70)) : chat.title)
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

private struct EdsgerInfoSheet: View {
    let background: Color
    let surface: Color
    let selection: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var mode: Mode = .chat
    @State private var step = 0
    @State private var showsTour = false

    private enum Mode: String, CaseIterable {
        case chat = "Chat", agent = "Agent"

        var title: String { self == .chat ? "Learn through conversation." : "Build inside your IDE." }
        var detail: String {
            self == .chat
                ? "Explore coding, math, science, and more with EDSGER. Ask follow-ups and work through ideas at your pace."
                : "Ask the coding agent to read, create, and edit project files, run code, and inspect output in your IDE."
        }
        var steps: [String] { self == .chat ? ["Ask", "Explore", "Practice"] : ["Request", "Work", "Review"] }
        var examples: [String] {
            self == .chat
                ? ["“Explain Python loops with a small example.”", "EDSGER explains in chat. Ask it to slow down, go deeper, or show another example.", "Try the example in the IDE. Chat can show code, but it cannot read, change, or run your files."]
                : ["“Add input validation to this program.”", "The agent inspects project code and uses local tools to make changes and run supported code.", "Inspect the changes and output in your IDE. You can stop the agent; deletion is blocked while safeguards are on."]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color.blue)
                            .frame(width: 60, height: 60)
                            .background(surface, in: Circle())
                            .accessibilityHidden(true)
                        Text("On your device.\nOn your terms.")
                            .font(.system(size: 32, weight: .semibold))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The AI is built into Edsger. Chat and coding-agent replies are generated on your device, without sending prompts to a cloud AI service.")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 0) {
                            ForEach(Mode.allCases, id: \.self) { item in
                                Button { mode = item; step = 0 } label: {
                                    Text(item.rawValue)
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(mode == item ? selection : .clear, in: Capsule())
                                }
                                .accessibilityAddTraits(mode == item ? [.isSelected] : [])
                                .accessibilityIdentifier("edsger-info-" + item.rawValue.lowercased())
                            }
                        }
                        .padding(4)
                        .background(background, in: Capsule())
                        VStack(alignment: .leading, spacing: 9) {
                            Text(mode.title).font(.system(size: 22, weight: .semibold))
                            Text(mode.detail).font(.system(size: 16)).foregroundStyle(.secondary)
                        }
                        Text("TAP THROUGH AN EXAMPLE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(0..<3) { index in
                                Button { step = index } label: {
                                    VStack(spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(step == index ? Color.white : Color.primary)
                                            .frame(width: 36, height: 36)
                                            .background(step == index ? Color.blue : selection, in: Circle())
                                        Text(mode.steps[index])
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Step \(index + 1): \(mode.steps[index])")
                                .accessibilityAddTraits(step == index ? [.isSelected] : [])
                            }
                        }
                        Text(mode.examples[step])
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(background, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(20)
                    .background(surface, in: RoundedRectangle(cornerRadius: 30))
                    .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(scheme == .dark ? 0.08 : 1)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 18, y: 6)

                    VStack(alignment: .leading, spacing: 0) {
                        infoAnswer("What works without Wi-Fi?", text: "Once Edsger is installed, the bundled AI can answer in Chat and work on code in Agent mode without an internet connection or a separate model download. Math calculations and supported code execution are local too.")
                        Divider().padding(.vertical, 16)
                        infoAnswer("What makes this different?", text: "Your device does the AI work. Chat and Agent do not need a cloud AI account or API key. Your conversations are saved locally, and the agent works with files in your IDE. Device backups and any files you choose to share follow your normal iOS settings.")
                        Divider().padding(.vertical, 16)
                        infoAnswer("What should I expect?", text: "Local AI can make mistakes and has no live web access. It is best used for focused questions and small coding tasks. Speed depends on your device and the size of the request; the first reply may take longer while the model loads.")
                    }
                    .padding(20)
                    .background(surface, in: RoundedRectangle(cornerRadius: 26))
                    Button { showsTour = true } label: {
                        HStack {
                            Text("Why Edsger")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.body.weight(.medium))
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("edsger-info-tour")
                    Text("Your files live in the IDE. Open IDE from Chat to manage projects and code.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(background)
            .foregroundStyle(Color.primary)
            .buttonStyle(.plain)
            .navigationTitle("Made to work offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .fullScreenCover(isPresented: $showsTour) {
            OnboardingView(isReplay: true) { showsTour = false }
        }
    }

    private func infoAnswer(_ title: String, text: String) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        } label: {
            Text(title).font(.system(size: 16, weight: .semibold))
                .padding(.vertical, 6)
        }
        .tint(.primary)
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
