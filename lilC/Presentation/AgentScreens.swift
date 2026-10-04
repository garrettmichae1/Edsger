import StoreKit
import SwiftUI

struct AgentPaywallScreen: View {
    let settings: AgentSettingsStore
    let back: () -> Void
    var openSettings: () -> Void = {}
    var body: some View { MembershipScreen(settings: settings, back: back) }
}

struct AgentChatScreen: View {
    let workspace: LocalCWorkspace
    let settings: AgentSettingsStore
    let back: () -> Void
    var openEditor: () -> Void = {}
    @State private var session: AgentSession

    init(workspace: LocalCWorkspace, settings: AgentSettingsStore, back: @escaping () -> Void, openEditor: @escaping () -> Void = {}) {
        self.workspace = workspace
        self.settings = settings
        self.back = back
        self.openEditor = openEditor
        _session = State(initialValue: AgentSession(workspace: workspace, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back")
                Spacer()
                Text("Edsger").font(.headline)
                Spacer()
                Button(action: openEditor) { Image(systemName: "chevron.left.forwardslash.chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Open editor")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.foreground)
            .padding(.horizontal, 8)
            AgentConversationView(session: session)
                .padding(.horizontal, 12)
        }
        .background(AppPalette.card)
    }
}

/// The editor's output panel remains the agent's home in both sizes.
struct AgentConversationView: View {
    @Bindable var session: AgentSession
    @FocusState private var composerFocused: Bool
    @State private var showsHistory = false
    @State private var showsRestorePoints = false
    @State private var pendingRestore: AgentCheckpointInfo?
    @State private var pendingDelete: AgentSavedConversation?

    private var visibleMessages: [AgentChatMessage] {
        AgentTranscriptPresentation.visibleMessages(session.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AgentModelPicker(session: session)
                Spacer()
                if !session.restorePoints.isEmpty {
                    Button { showsRestorePoints = true } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Project restore points")
                    .accessibilityIdentifier("agent-restore-points")
                    .disabled(session.isThinking)
                }
                Button { showsHistory = true } label: {
                    Image(systemName: "clock").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Agent conversation history")
                .accessibilityIdentifier("agent-history")
                .disabled(!session.canManageConversations)
                Button { session.newConversation(); composerFocused = true } label: {
                    Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                }
                .accessibilityLabel("New agent chat")
                .accessibilityIdentifier("agent-new-chat")
                .disabled(!session.canManageConversations)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.silver)
            .font(.system(size: 15))

            ConversationTranscript(conversationID: session.conversationID,
                                   revision: session.messages.count,
                                   sentMessageID: session.messages.last(where: { $0.role == .user })?.id) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visibleMessages.isEmpty {
                        Text("Ask about your code, fix an error, or make a change.")
                            .font(.callout)
                            .foregroundStyle(AppPalette.silver)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("agent-empty-state")
                    }
                    ForEach(visibleMessages) { message in
                        AgentBubble(message: message).id(message.id)
                    }
                    if session.isThinking {
                        HStack(alignment: .top, spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(AgentTranscriptPresentation.status(session.statusLine))
                                .font(.footnote)
                                .foregroundStyle(AppPalette.silver)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("agent-generation-status")
                        .padding(.vertical, 4)
                    } else if session.statusLine == "Stopped" || session.statusLine == "Error" {
                        Text(session.statusLine == "Error" ? "Couldn’t complete this request." : "Stopped")
                            .font(.footnote)
                            .foregroundStyle(AppPalette.silver)
                    }
                    if let notice = session.notice {
                        Text(notice).font(.footnote).foregroundStyle(AppPalette.silver)
                            .accessibilityIdentifier("agent-notice")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipped()

            composer
        }
        .background(AppPalette.card)
        .onAppear { session.activateCurrentProject() }
        .onChange(of: session.workspaceProjectPath) { _, _ in session.activateCurrentProject() }
        .sheet(isPresented: $showsHistory) { historySheet }
        .sheet(isPresented: $showsRestorePoints) { restoreSheet }
    }

    private var historySheet: some View {
        NavigationStack {
            List {
                if session.conversationHistory.isEmpty {
                    Text("Your agent chats for this project will appear here.").foregroundStyle(.secondary)
                }
                ForEach(session.conversationHistory) { conversation in
                    HStack(spacing: 0) {
                        Button {
                            session.openConversation(conversation)
                            showsHistory = false
                        } label: {
                            HStack {
                                if conversation.isPinned {
                                    Image(systemName: "pin.fill").foregroundStyle(Color.blue)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title).foregroundStyle(.primary).lineLimit(2)
                                    Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if conversation.id == session.conversationID { Image(systemName: "checkmark") }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(conversation.isPinned ? "Pinned" : "")
                        .accessibilityAction(named: conversation.isPinned ? "Unpin chat" : "Pin chat") {
                            session.toggleConversationPin(conversation.id)
                        }
                        .accessibilityAction(named: "Delete chat") { pendingDelete = conversation }
                        Menu {
                            ConversationHistoryActions(isPinned: conversation.isPinned,
                                                       pin: { session.toggleConversationPin(conversation.id) },
                                                       delete: { pendingDelete = conversation })
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Chat options for \(conversation.title)")
                        .accessibilityIdentifier("agent-chat-options-\(conversation.id)")
                    }
                    .disabled(!session.canManageConversations)
                    .contextMenu {
                        ConversationHistoryActions(isPinned: conversation.isPinned,
                                                   pin: { session.toggleConversationPin(conversation.id) },
                                                   delete: { pendingDelete = conversation })
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            session.toggleConversationPin(conversation.id)
                        } label: {
                            Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(Color.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = conversation }
                    }
                }
                if let notice = session.notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Agent chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsHistory = false } } }
            .safeAreaInset(edge: .bottom) {
                Text(session.projectTitle).font(.footnote).foregroundStyle(.secondary).padding(10)
            }
            .alert("Delete agent chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { conversation in
                Button("Delete", role: .destructive) { session.deleteConversation(conversation.id); pendingDelete = nil }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("This conversation will be permanently deleted. Your project files and restore points will be kept.")
            }
        }
    }

    private var restoreSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Restore " + session.restoreScopeDescription + " to before an agent change. Later edits in that scope will also be replaced; a recovery copy lets you undo the rollback.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !session.canRestore { Text("Stop the running program before restoring.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section(session.projectTitle) {
                    ForEach(session.restorePoints) { point in
                        Button { pendingRestore = point } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(point.isRecovery ? "Undo rollback" : "Before: " + point.request)
                                    .foregroundStyle(.primary).lineLimit(3)
                                Text(point.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!session.canRestore)
                    }
                }
            }
            .navigationTitle("Restore points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsRestorePoints = false } } }
            .confirmationDialog("Restore this project?", isPresented: Binding(
                get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }
            ), titleVisibility: .visible) {
                if let point = pendingRestore {
                    Button("Restore project", role: .destructive) {
                        session.restore(point)
                        pendingRestore = nil
                        showsRestorePoints = false
                    }
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("Replaces files in " + session.restoreScopeDescription + " with the selected restore point. A recovery copy preserves the current files.")
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Edsger", text: $session.draft, prompt: Text("Ask Edsger").foregroundStyle(AppPalette.silver), axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .font(.body)
                .lilCFieldInk()
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppPalette.line.opacity(0.6)))
                .accessibilityLabel("Message Edsger about this project")
                .accessibilityIdentifier("agent-composer")
                .onSubmit { sendRequest() }

            Button {
                if session.isThinking { session.stop() }
                else { sendRequest() }
            } label: {
                Image(systemName: session.isThinking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(AppPalette.onAccent)
                    .background(session.isThinking ? AppPalette.amber : AppPalette.green, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isThinking ? "Stop Edsger" : "Send to Edsger")
            .accessibilityIdentifier("agent-send-stop")
            .disabled(!session.isThinking && session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(AppPalette.card)
        .overlay(alignment: .top) { Rectangle().fill(AppPalette.line.opacity(0.45)).frame(height: 0.5) }
        .layoutPriority(1)
    }

    private func sendRequest() {
        // Return in the field must not unexpectedly stop an active task.
        guard !session.isThinking else { return }
        session.send()
        composerFocused = false
    }
}

private struct AgentBubble: View {
    let message: AgentChatMessage

    var body: some View {
        if message.role == .tool {
            AgentActivityRow(message: message)
        } else if message.role == .user {
            HStack(alignment: .top) {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(AppPalette.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 22))
            }
        } else {
            MathAnswerView(text: message.text)
                .foregroundStyle(AppPalette.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentActivityRow: View {
    let message: AgentChatMessage
    @State private var isExpanded = false

    init(message: AgentChatMessage) {
        self.message = message
        _isExpanded = State(initialValue: AgentToolActivity(message: message).showsDetailsInitially)
    }

    var body: some View {
        let activity = AgentToolActivity(message: message)
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(message.text)
                .font(.footnote.monospaced())
                .foregroundStyle(AppPalette.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label(activity.title, systemImage: activity.symbol)
                .font(.footnote)
                .foregroundStyle(AppPalette.silver)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(AppPalette.silver)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppPalette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("agent-activity-" + message.id.uuidString)
    }
}
