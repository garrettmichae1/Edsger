import SwiftUI

struct BYOKSettingsScreen: View {
    let back: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var store = BYOKStore.shared
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        .frame(width: 48, height: 48).background(surface, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Back to Settings")
                Text("BYOK").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "key.fill").font(.title).foregroundStyle(.blue)
                        Text("Your models. Edsger’s tools.").font(.title2.weight(.semibold))
                        Text("Bring your own OpenAI or Claude API key. Choose a model for Chat or let it work on your IDE projects.")
                            .foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    ForEach(BYOKProvider.allCases) { provider in
                        BYOKProviderCard(provider: provider, store: store)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("How it works").font(.headline)
                        Text("Chat keeps its document and on-device math tools. Agent IDE can create and edit project files, run supported code, inspect output, and use on-device math. Your model choice never expands file permissions.")
                        Text("API usage is billed by your selected provider, separately from Edsger. Consumer subscriptions do not supply an API key. Edsger never switches providers or paying accounts automatically.")
                        Text("Keys are stored securely on this device. Requests pass through Edsger’s secure relay and Cloudflare to your chosen provider. The relay processes the key and request in memory without saving them. Provider handling follows its data policy.")
                    }.font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.bottom, 28)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.background(background.ignoresSafeArea()).foregroundStyle(Color.primary).tint(.blue)
        .accessibilityIdentifier("byok.root")
    }
}

private struct BYOKProviderCard: View {
    let provider: BYOKProvider
    @Bindable var store: BYOKStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var draftKey = ""
    @State private var models: [BYOKModel] = []
    @State private var modelID = ""
    @State private var consent = false
    @State private var status: String?
    @State private var failed = false
    @State private var pendingTask: Task<Void, Never>?
    @State private var confirmRemove = false
    private var configured: Bool { store.configurations[provider.rawValue] != nil }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(provider.title).font(.headline)
                Spacer()
                if configured { Label("Saved", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary) }
            }
            SecureField(configured ? "Enter replacement API key" : "API key", text: $draftKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.password).privacySensitive()
                .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!store.canConfigure)
                .accessibilityIdentifier("byok." + provider.rawValue + ".key")
            Toggle(isOn: $consent) {
                Text("Allow sharing with " + provider.title).font(.subheadline.weight(.medium))
            }
            .onChange(of: consent) { _, value in
                if !value { pendingTask?.cancel() }
                if configured { store.setConsent(value, provider: provider) }
            }
            Text("When selected, your prompts, conversation context, file passages, IDE source and tool results are sent through Edsger’s relay to " + provider.title + ". Testing a model makes small billable API requests. You can turn sharing off anytime.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Load models") { start {
                models = try await store.loadModels(provider: provider, draftKey: draftKey, consent: consent)
                if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
                status = "Choose a model, then test and save."
            } }
                .disabled(!store.canConfigure || !consent || (!configured && draftKey.isEmpty))
                .accessibilityIdentifier("byok." + provider.rawValue + ".load")
            if !models.isEmpty {
                Picker("Model", selection: $modelID) {
                    ForEach(models) { model in Text(model.name).tag(model.id) }
                }.pickerStyle(.menu).disabled(!store.canConfigure)
                    .accessibilityIdentifier("byok." + provider.rawValue + ".model")
                Button("Test & save") { start {
                    try await store.save(provider: provider, draftKey: draftKey, modelID: modelID, models: models, consent: consent)
                    draftKey = ""; status = "Saved. This model passed the agent tool test."
                } }
                .buttonStyle(.borderedProminent).disabled(!store.canConfigure || !consent || modelID.isEmpty)
                .accessibilityIdentifier("byok." + provider.rawValue + ".save")
            }
            if let config = store.configurations[provider.rawValue] {
                Text("Saved model: " + (config.models.first(where: { $0.id == config.modelID })?.name ?? config.modelID))
                    .font(.caption).foregroundStyle(.secondary)
                ViewThatFits {
                    HStack(spacing: 14) { defaultsButtons(config) }
                    VStack(alignment: .leading, spacing: 14) { defaultsButtons(config) }
                }.font(.subheadline).disabled(!store.canConfigure || !consent)
                Button("Remove key", role: .destructive) { confirmRemove = true }.font(.subheadline).disabled(!store.canConfigure)
            }
            if pendingTask != nil { ProgressView("Checking connection…").font(.caption) }
            if let status { Text(status).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.06)))
        .task { if let config = store.configurations[provider.rawValue] { models = config.models; modelID = config.modelID; consent = config.sharingConsent } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pendingTask?.cancel(); draftKey = "" } }
        .onDisappear { pendingTask?.cancel(); draftKey = "" }
        .alert("Remove " + provider.title + " key?", isPresented: $confirmRemove) {
            Button("Remove key", role: .destructive) {
                do { try store.remove(provider); draftKey = ""; models = []; modelID = ""; consent = false; failed = false; status = "Key removed from this device. Revoke it with the provider if needed." }
                catch { failed = true; status = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Existing conversations and project files are kept. Selected models will ask for a replacement key.") }
    }
    @ViewBuilder private func defaultsButtons(_ config: BYOKConfiguration) -> some View {
        Button("Use for Chat") { store.selectChat(.init(provider: provider, modelID: config.modelID)); status = "Selected for Chat." }
        Button("Use for Agent IDE") { store.selectAgentDefault(.init(provider: provider, modelID: config.modelID)); status = "Default for new IDE project selections. Existing project choices are kept." }
    }
    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard pendingTask == nil, store.canConfigure else { return }
        failed = false; status = nil
        pendingTask = Task { @MainActor in
            defer { pendingTask = nil }
            do { try await operation() }
            catch is CancellationError { status = "Connection test stopped." }
            catch { failed = true; status = error.localizedDescription }
        }
    }
}

struct AgentModelPicker: View {
    @Bindable var session: AgentSession
    @State private var providers = BYOKStore.shared
    @State private var showsBYOK = false
    var body: some View {
        Menu {
            Button("Edsger 1.0 · On device") { session.selectModel(nil) }
            ForEach(providers.choices) { choice in
                Button(providers.title(choice)) { session.selectModel(choice) }
            }
            Divider()
            Button("Manage API keys…") { showsBYOK = true }
        } label: {
            HStack(spacing: 5) {
                Text(session.modelTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
        }.disabled(session.isThinking || !providers.canConfigure)
            .accessibilityLabel("Agent model: " + session.modelTitle).accessibilityIdentifier("agent-model-picker")
            .sheet(isPresented: $showsBYOK) { BYOKSettingsScreen { showsBYOK = false } }
    }
}
