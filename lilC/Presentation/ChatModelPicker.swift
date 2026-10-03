import SwiftUI

/// A native compact menu shared by Chat and Settings.
struct ChatModelPicker: View {
    @State private var models = ChatModelStore.shared

    var body: some View {
        Menu {
            ForEach(ChatModel.allCases) { model in
                Button {
                    Task { await models.select(model) }
                } label: {
                    Text(model.title)
                }
                .disabled(!models.canChange || (model == .mini && !models.miniAvailable))
            }
        } label: {
            HStack(spacing: 6) {
                Text(models.selected.title)
                    .accessibilityIdentifier("edsger-title")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(!models.canChange)
        .accessibilityLabel("Chat model: " + models.selected.title)
        .accessibilityHint("Choose a model")
        .accessibilityIdentifier("edsger-model-picker")
        .task { await models.refresh() }
    }
}
