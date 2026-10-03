import SwiftUI

/// A native compact menu shared by Chat and Settings.
struct ChatModelPicker: View {
    @State private var models = ChatModelStore.shared
    @State private var providers = BYOKStore.shared
    @State private var showsBYOK = false
    private var title: String { providers.chatChoice.map(providers.title) ?? models.selected.title }

    var body: some View {
        Menu {
            ForEach(ChatModel.allCases) { model in
                Button {
                    Task { await models.select(model); providers.selectChat(nil) }
                } label: {
                    Text(model.title)
                }
                .disabled(!models.canChange || (model == .mini && !models.miniAvailable))
            }
            if !providers.choices.isEmpty {
                Divider()
                ForEach(providers.choices, id: \.provider) { choice in
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
        .disabled(!models.canChange || !providers.canConfigure)
        .accessibilityLabel("Chat model: " + title)
        .accessibilityHint("Choose a model")
        .accessibilityIdentifier("edsger-model-picker")
        .task { await models.refresh() }
        .sheet(isPresented: $showsBYOK) { BYOKSettingsScreen { showsBYOK = false } }
    }
}
