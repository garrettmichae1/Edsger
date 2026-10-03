import StoreKit
import SwiftUI

struct AgentPaywallScreen: View {
    let settings: AgentSettingsStore
    let back: () -> Void
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                }
                Text("Edsger Agent")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(12)
            .background(AppPalette.panel)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A coding agent on your iPhone.")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppPalette.foreground)

                    Text("Prompt in chat. The agent can create folders and source files, write tests, run the selected language, and brainstorm. Deleting stays locked until you turn safeguards off. The editor stays free.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppPalette.silver)
                        .lineSpacing(4)

                    VStack(alignment: .leading, spacing: 10) {
                        PaywallPoint(title: "Extra turns", detail: "The free pool is small so everyone can get a turn. This Apple subscription adds extra agent requests on the app’s worker. No personal OpenAI keys.")
                        PaywallPoint(title: "Controls the IDE", detail: "Projects, files, tests, and Run — with delete locked by default.")
                        PaywallPoint(title: "Off in one switch", detail: "Settings → Show Agent. Turn it off and you only have the free IDE.")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(priceLine)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppPalette.green)
                        Text("Auto-renewable subscription billed by Apple. Cancel in Settings → Apple ID → Subscriptions. Payment is charged to your Apple ID. Unused trial portions, if any, are forfeited when you buy.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppPalette.silver)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.line.opacity(0.7)))

                    Button {
                        Task { await settings.purchase() }
                    } label: {
                        Text(settings.isPurchasing ? "WORKING…" : "SUBSCRIBE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppPalette.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(AppPalette.green, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .disabled(settings.isPurchasing)

                    Button("RESTORE PURCHASES") {
                        Task { await settings.restore() }
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.amber)
                    .frame(maxWidth: .infinity)

                    Button("Privacy, terms, and Apple EULA are in Settings", action: openSettings)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppPalette.silver)

                    if let storeMessage = settings.storeMessage {
                        Text(storeMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppPalette.amber)
                    }

                    #if DEBUG
                    Toggle(isOn: debugUnlockBinding) {
                        Text("DEBUG: preview Agent without StoreKit")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.silver)
                    }
                    .tint(AppPalette.green)
                    #endif
                }
                .padding(16)
            }
            .background(AppPalette.background)
        }
        .background(AppPalette.background)
        .task { await settings.loadStore() }
    }

    private var priceLine: String {
        if let product = settings.monthlyProduct {
            return "\(product.displayPrice) / month — Edsger Agent"
        }
        return "Edsger Agent monthly  ·  product lilc.agent.monthly"
    }

    #if DEBUG
    private var debugUnlockBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "lilc.agent.debugUnlock") },
            set: { value in
                UserDefaults.standard.set(value, forKey: "lilc.agent.debugUnlock")
                Task { await settings.refreshEntitlements() }
            }
        )
    }
    #endif
}

private struct PaywallPoint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(AppPalette.foreground)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppPalette.silver)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.line.opacity(0.7)))
    }
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

    private var visibleMessages: [AgentChatMessage] {
        AgentTranscriptPresentation.visibleMessages(session.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationTranscript(conversationID: session.messages.first?.id,
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
