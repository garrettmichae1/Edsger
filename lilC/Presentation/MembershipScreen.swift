import StoreKit
import SwiftUI

struct MembershipScreen: View {
    let settings: AgentSettingsStore
    let back: () -> Void
    @State private var mobile = MobileAgentStore.shared
    @Environment(\.colorScheme) private var scheme
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        .frame(width: 48, height: 48).background(surface, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Back")
                Text("Membership").font(.title2.weight(.semibold))
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "bolt.fill").font(.title).foregroundStyle(.blue)
                        Text(MobileAgentConfiguration.title).font(.title2.weight(.semibold))
                        Text("Your flagship mobile agent. Build in the IDE, think in Chat.").foregroundStyle(.secondary)
                        Text("Create and edit files, run supported code, check results and use on-device math. Your files keep the same safeguards and restore points.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !MobileAgentConfiguration.isEnabled {
                        Label("Coming soon", systemImage: "clock").font(.subheadline.weight(.medium))
                        Text("Membership purchases will open when Dijkstra is ready.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let plan = settings.membership {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(plan.title, systemImage: "checkmark.shield").font(.headline)
                            if let allowance = mobile.allowance {
                                ProgressView(value: allowance.remainingFraction).tint(.blue)
                                Text("\(Int(allowance.remainingFraction * 100))% of your monthly allowance remaining")
                                Text("Renews \(allowance.renewalDate.formatted(date: .abbreviated, time: .omitted))")
                                    .foregroundStyle(.secondary)
                            } else { Text("Your allowance is shared between Chat and Agent IDE.").foregroundStyle(.secondary) }
                            Link("Manage membership", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        }.font(.subheadline).padding(18).background(surface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    ForEach(EdsgerMembership.allCases) { plan in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(plan.title).font(.headline)
                                Spacer()
                                Text((settings.products[plan.rawValue]?.displayPrice ?? "$\(plan.monthlyUSD)") + " / month")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("Includes $\(plan.allowanceUSD) in monthly AI allowance, shared across Chat and Agent IDE.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                Task { await settings.purchase(plan) }
                            } label: {
                                Text(settings.isPurchasing ? "Working…" : settings.membership == plan ? "Current membership" : "Choose " + plan.title)
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent)
                                .disabled(!MobileAgentConfiguration.isEnabled || settings.isPurchasing || settings.membership == plan || settings.products[plan.rawValue] == nil)
                                .accessibilityIdentifier("membership." + plan.rawValue)
                        }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.06)))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Allow sharing with Dijkstra", isOn: Binding(get: { settings.sharingConsent }, set: { settings.sharingConsent = $0 }))
                            .font(.subheadline.weight(.medium)).accessibilityIdentifier("membership.sharing-consent")
                        Text("Dijkstra sends your prompts, conversation context, file passages, IDE source and tool results through Edsger’s secure service to DeepSeek. You can turn sharing off anytime. Code and math execute on your device.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Dijkstra is the default for members who allow sharing. When its usage limit is reached, future requests use your on-device model. A coding task already in progress pauses safely; completed edits are kept. BYOK remains your separate choice.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Allowance renews each billing period and does not roll over. Usage varies with the size of your requests. Both memberships include the same agent and tools.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(surface, in: RoundedRectangle(cornerRadius: 24))
                    Button("Restore purchases") { Task { await settings.restore(); await mobile.refresh() } }
                        .disabled(settings.isPurchasing)
                    if let message = settings.storeMessage ?? mobile.notice {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Monthly subscription billed by Apple and automatically renewed unless canceled. Manage or cancel in your Apple account. Apple displays the final price before purchase.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Link("Privacy", destination: LegalURLs.privacy)
                        Link("Terms", destination: LegalURLs.terms)
                        Link("Apple EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }.font(.caption)
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.background(background.ignoresSafeArea()).foregroundStyle(Color.primary).tint(.blue)
        .accessibilityIdentifier("membership.root")
        .task { await settings.loadStore(); await mobile.refresh() }
    }
}
