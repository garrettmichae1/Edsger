import SwiftUI

/// A native compact menu shared by Chat and Settings.
struct ChatModelPicker: View {
    @State private var models = ChatModelStore.shared
    @State private var providers = BYOKStore.shared
    @State private var showsBYOK = false
    @State private var showsMembership = false
    @State private var mobile = MobileAgentStore.shared
    private var title: String { providers.chatChoice.map(providers.title) ?? (mobile.usesCloudForChat ? MobileAgentConfiguration.title : models.selected.title) }

    var body: some View {
        Menu {
            Button(MobileAgentConfiguration.title) {
                if mobile.isEligible {
                    providers.selectChat(nil); mobile.selectChat(.flagship)
                    Task { await mobile.refresh() }
                } else { showsMembership = true }
            }
            Divider()
            ForEach(ChatModel.allCases) { model in
                Button {
                    Task { await models.select(model); providers.selectChat(nil); mobile.selectChat(.local) }
                } label: {
                    Text(model.title)
                }
                .disabled(!models.canChange || (model == .mini && !models.miniAvailable))
            }
            if !providers.choices.isEmpty {
                Divider()
                ForEach(providers.choices) { choice in
                    Button(providers.title(choice)) { providers.selectChat(choice) }
                }
            }
            Divider()
            Button("Manage API keys…") { showsBYOK = true }
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                    .accessibilityIdentifier("edsger-title")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!models.canChange || !providers.canConfigure || !mobile.canChange)
        .accessibilityLabel("Chat model: " + title)
        .accessibilityHint("Choose a model")
        .accessibilityIdentifier("edsger-model-picker")
        .task { await models.refresh() }
        .sheet(isPresented: $showsBYOK) { BYOKSettingsScreen { showsBYOK = false } }
        .sheet(isPresented: $showsMembership) { MembershipScreen(settings: .shared) { showsMembership = false } }
    }
}
