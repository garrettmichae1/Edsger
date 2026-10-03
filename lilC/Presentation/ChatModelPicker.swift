import SwiftUI

struct ChatModelPicker: View {
    @State private var models = ChatModelStore.shared
    @State private var confirmRemoval = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.97) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose your Chat model")
                        .font(.title2.weight(.semibold))
                    Text("Both run on your device. Your conversations stay here when you switch.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(ChatModel.allCases) { model in
                        modelCard(model)
                    }
                    if models.isChanging {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing model…").font(.subheadline)
                        }
                        .accessibilityIdentifier("models.preparing")
                    } else if models.activeReplies > 0 {
                        Text("Finish or stop the response before changing models.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = models.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("models.error")
                    }
                    Text("Math calculations and formatting are available with either model. Edsger interprets calculation requests; Mini can explain the results. AI explanations can still contain mistakes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Only one model is loaded at a time. Calculations and the IDE agent use Edsger, so switching may take a moment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(background.ignoresSafeArea())
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.blue)
        .task { await models.refresh() }
        .alert("Delete Edsger mini?", isPresented: $confirmRemoval) {
            Button("Delete download", role: .destructive) { Task { await models.removeMini() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees about 731 MB and switches Chat to Edsger. Your chats and projects are kept. You can download Mini again anytime.")
        }
        .accessibilityIdentifier("models.picker")
    }

    private func modelCard(_ model: ChatModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                Task { await models.select(model) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.title).font(.headline)
                        Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: models.selected == model ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(models.selected == model ? Color.blue : Color.secondary)
                        .font(.title3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!models.canChange || (model == .mini && !models.miniInstalled))
            .accessibilityLabel("Use " + model.title)
            .accessibilityAddTraits(models.selected == model ? [.isSelected] : [])
            .accessibilityIdentifier("models.select." + model.rawValue)

            if model == .mini {
                Text("Powered by Liquid AI · LFM2.5 1.2B")
                    .font(.caption).foregroundStyle(.secondary)
                if models.isDownloading {
                    ProgressView(value: models.downloadProgress)
                    HStack {
                        Text(models.downloadProgress >= 1 ? "Verifying download…" : "Downloading \(Int(models.downloadProgress * 100))%")
                            .font(.footnote).monospacedDigit()
                        Spacer()
                        Button("Cancel") { models.cancelDownload() }
                    }
                } else if models.miniInstalled {
                    Button("Delete download", role: .destructive) { confirmRemoval = true }
                        .disabled(!models.canChange)
                        .accessibilityIdentifier("models.delete-mini")
                } else {
                    Text("Optional 731 MB download from Hugging Face. Wi-Fi recommended. After downloading, select Mini above to try it offline.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Download Edsger mini") { models.downloadMini() }
                        .buttonStyle(.borderedProminent)
                        .disabled(models.isChanging)
                        .accessibilityIdentifier("models.download-mini")
                }
                Link("Liquid model license", destination: MiniModelAsset.licenseURL)
                    .font(.caption)
            } else {
                Text("Included · Qwen3.5 4B")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }
}
