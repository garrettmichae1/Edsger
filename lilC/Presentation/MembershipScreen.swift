import StoreKit
import SwiftUI

/// Native sales surface. Provider disclosure and permission live in a separate,
/// explicitly opened privacy screen; purchasing never grants sharing consent.
struct MembershipScreen: View {
    let settings: AgentSettingsStore
    let back: () -> Void
    @State private var mobile = MobileAgentStore.shared
    @State private var selectedPlan: EdsgerMembership = .pro
    @State private var hasSelectedPlan = false
    @State private var showsCloudPrivacy = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 42
    private let actionBlue = Color(red: 0.08, green: 0.36, blue: 0.98)
    private var accent: Color { scheme == .dark ? Color(red: 0.40, green: 0.65, blue: 1) : actionBlue }
    private var background: Color { scheme == .dark ? Color(white: 0.055) : Color(white: 0.985) }
    private var surface: Color { scheme == .dark ? Color(white: 0.10) : .white }
    private var currentPlan: EdsgerMembership? { settings.isSubscribed ? settings.membership : nil }
    private var canPurchase: Bool {
        MobileAgentConfiguration.isEnabled && !settings.isPurchasing && currentPlan != selectedPlan && settings.products[selectedPlan.rawValue] != nil
    }
    @MainActor init(settings: AgentSettingsStore, back: @escaping () -> Void) {
        self.settings = settings
        self.back = back
        _selectedPlan = State(initialValue: settings.isSubscribed ? (settings.membership ?? .pro) : .pro)
    }

    private func price(_ plan: EdsgerMembership) -> String {
        settings.products[plan.rawValue]?.displayPrice ?? "US$\(plan.monthlyUSD)"
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    if currentPlan != nil { membershipStatus }
                    agentPreview
                    planSelection
                    benefits
                    membershipDetails
                    legalFooter
                }
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 28)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("membership.scroll")
        }
        .background(background.ignoresSafeArea()).foregroundStyle(Color.primary).tint(accent)
        .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }
        .accessibilityIdentifier("membership.root")
        .sheet(isPresented: $showsCloudPrivacy) {
            DijkstraPrivacyScreen(settings: settings) { showsCloudPrivacy = false }
        }
        .onChange(of: settings.membership) { _, plan in
            if let plan, !hasSelectedPlan { selectedPlan = plan }
        }
        .task {
            await settings.loadStore()
            await mobile.refresh()
        }
    }

    private var navigationBar: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44).background(surface, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Close membership")
            Spacer()
            Text("EDSGER PRO").font(.caption.weight(.bold)).tracking(2)
            Spacer()
            Image(systemName: "sparkle").foregroundStyle(accent).frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(currentPlan == nil ? "YOUR NEXT IDEA STARTS HERE" : "YOUR PRO WORKSPACE")
                .font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
            Text("Build what’s next.\nFrom your phone.")
                .font(.system(size: headlineSize, weight: .bold, design: .rounded))
                .tracking(-1.3).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Go from “what if” to working code with a capable AI agent inside your pocket-sized IDE.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("Dijkstra Super Fast 1.0", systemImage: "bolt.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
        }
    }

    private var agentPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "terminal.fill").foregroundStyle(Color(red: 0.48, green: 0.66, blue: 1))
                Text("IDE + AGENT").font(.caption.weight(.bold)).tracking(1.4)
                Spacer()
                Text("Example").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            Text("“Build a Python expense tracker.\nSave entries and show my totals.”")
                .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                previewStep("doc.text.magnifyingglass", "Understand your project")
                previewStep("curlybraces", "Create and edit the code")
                previewStep("play.circle", "Run it. Inspect the results.")
            }.font(.subheadline).foregroundStyle(.white.opacity(0.82))
            Divider().overlay(.white.opacity(0.12))
            Text("You bring the idea. Your agent helps with the next steps.")
                .font(.caption).foregroundStyle(.white.opacity(0.62))
        }
        .padding(22).foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.23), Color(red: 0.04, green: 0.06, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.08)))
    }

    private func previewStep(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
    }

    private var planSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your room to build.").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text("One flagship agent. Two monthly allowances.")
                .font(.subheadline).foregroundStyle(.secondary)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout { ForEach(EdsgerMembership.allCases) { plan in planCard(plan) } }
            if EdsgerMembership.allCases.contains(where: { settings.products[$0.rawValue] == nil }) {
                Text("Prices shown before Apple options load are planned US prices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Dijkstra in Chat and IDE. OpenAI and Claude BYOK. Included in both plans.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planCard(_ plan: EdsgerMembership) -> some View {
        let selected = selectedPlan == plan
        return Button {
            hasSelectedPlan = true
            selectedPlan = plan
            AppHaptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text(plan == .pro ? "Pro" : "Pro Plus").font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? accent : Color.secondary)
                }
                Text(plan == .pro ? "Everyday building" : "3× AI allowance")
                    .font(.caption2.weight(.semibold)).foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(price(plan)).font(.title2.weight(.bold)).monospacedDigit()
                    Text("per month").font(.caption).foregroundStyle(.secondary)
                }
                Text("US$\(plan.allowanceUSD)").font(.headline)
                Text("monthly AI allowance").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan == .pro ? "For everyday ideas." : "3× the Pro allowance.")
                    .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if currentPlan == plan {
                    Text("YOUR PLAN").font(.caption2.weight(.bold)).foregroundStyle(accent)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? accent.opacity(scheme == .dark ? 0.13 : 0.045) : surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(selected ? accent : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain).disabled(settings.isPurchasing)
        .accessibilityLabel("\(plan.title), \(price(plan)) per month, US$\(plan.allowanceUSD) monthly AI allowance")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("membership." + plan.rawValue)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("More than a chat window.").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            benefit("hammer.fill", "Work on the actual project.", "Ask your agent to create files, improve code and investigate errors. Review the changes in your IDE.")
            benefit("bubble.left.and.bubble.right.fill", "Keep your thinking moving.", "Use Dijkstra in Chat to explore ideas, understand code and work through problems with on-device math tools.")
            benefit("key.fill", "Your favorite models. Your workflow.", "Connect your own OpenAI or Claude API key and use supported models with Edsger’s agent tools.")
            benefit("iphone", "A real coding workspace. Wherever you are.", "Build with Python, C, JavaScript and Lua. Run supported code on your device and keep restore points as you work.")
        }
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(accent)
                .frame(width: 42, height: 42).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var membershipStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(currentPlan?.title ?? "Edsger Pro", systemImage: "checkmark.seal.fill").font(.headline)
            if let allowance = mobile.allowance, allowance.renewalDate > Date() {
                ProgressView(value: allowance.remainingFraction).tint(accent)
                Text("\(Int(allowance.remainingFraction * 100))% of your monthly AI allowance remaining").font(.subheadline)
                Text("Allowance renews \(allowance.renewalDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Your allowance works across Chat and Agent IDE.").font(.subheadline).foregroundStyle(.secondary)
            }
            if !settings.sharingConsent {
                Button("Set up Dijkstra") { showsCloudPrivacy = true }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
            }
            Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                .font(.subheadline).foregroundStyle(accent)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var membershipDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("How does the AI allowance work?") {
                Text("Your monthly allowance covers Dijkstra usage in Chat and IDE. Request size and responses affect usage; there is no fixed message count. Allowance renews each billing period and does not roll over. Up to US$0.33 may remain unusable because each request needs a safety reserve. When limits are reached, future requests use local AI. A coding task in progress pauses and keeps completed edits.")
                    .padding(.top, 8)
            }
            DisclosureGroup("How does BYOK work?") {
                Text("Both plans let you connect supported OpenAI and Claude models using your own API keys. Your provider bills API usage separately; it does not reduce your Dijkstra allowance. A consumer AI subscription is not an API key.")
                    .padding(.top, 8)
            }
            DisclosureGroup("What happens if I cancel?") {
                Text("Pro access continues until your verified subscription expires. Your local projects, editor, language runtimes and on-device AI remain available. Saved API keys stay on this device until you remove them; using BYOK again requires an active membership.")
                    .padding(.top, 8)
            }
            Button { showsCloudPrivacy = true } label: {
                Label("Cloud privacy & permissions", systemImage: "hand.raised")
            }.foregroundStyle(accent).frame(minHeight: 44).accessibilityIdentifier("membership.cloud-privacy")
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .padding(18).background(surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Restore purchases") { Task { await settings.restore(); await mobile.refresh() } }
                .disabled(settings.isPurchasing).foregroundStyle(accent).frame(minHeight: 44)
                .accessibilityIdentifier("membership.restore")
            if let message = settings.storeMessage ?? mobile.notice {
                Text(message).font(.caption).accessibilityIdentifier("membership.message")
            }
            if !MobileAgentConfiguration.isEnabled {
                Text("Pro is coming soon. Purchases are unavailable until the service is ready. Prices shown before Apple options load are planned US prices.")
            }
            Text("Monthly subscription. Payment is charged to your Apple account at confirmation. Renews automatically unless canceled at least 24 hours before the current period ends. Manage or cancel in Apple account settings. Apple shows the final local price before you confirm. Cloud AI requires internet access and separate sharing permission.")
            HStack(spacing: 16) {
                Link("Privacy", destination: LegalURLs.privacy)
                Link("Terms", destination: LegalURLs.terms)
                Link("Apple EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }.foregroundStyle(accent)
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var purchaseBar: some View {
        VStack(spacing: 8) {
            if !MobileAgentConfiguration.isEnabled {
                Text("PRO IS COMING SOON").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            } else {
                Text("\(selectedPlan.title) · \(price(selectedPlan)) / month").font(.caption.weight(.medium))
            }
            Button {
                Task { await settings.purchase(selectedPlan); await mobile.refresh() }
            } label: {
                HStack(spacing: 10) {
                    if settings.isPurchasing { ProgressView().tint(accent) }
                    Text(purchaseTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if canPurchase { Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)) }
                }.frame(maxWidth: .infinity).padding(.vertical, 17)
            }
            .buttonStyle(.plain).foregroundStyle(canPurchase ? Color.white : Color.primary.opacity(0.65))
            .background(canPurchase ? actionBlue : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .disabled(!canPurchase).accessibilityIdentifier("membership.purchase")
            if MobileAgentConfiguration.isEnabled && settings.products[selectedPlan.rawValue] == nil {
                Button("Reload membership options") { Task { await settings.loadStore() } }
                    .font(.caption).frame(minHeight: 44).disabled(settings.isPurchasing)
            } else {
                Text("Monthly billing. Cancel anytime.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .background(surface.shadow(.drop(color: .black.opacity(0.06), radius: 12, y: -4)))
    }

    private var purchaseTitle: String {
        if settings.isPurchasing { return "Confirming with Apple…" }
        if currentPlan == selectedPlan { return "Your current plan" }
        if !MobileAgentConfiguration.isEnabled { return "Unlock your next chapter" }
        if settings.products[selectedPlan.rawValue] == nil { return "Membership options unavailable" }
        return currentPlan == nil ? "Get \(selectedPlan.title)" : "Change to \(selectedPlan.title)"
    }
}

struct DijkstraPrivacyScreen: View {
    let settings: AgentSettingsStore
    let back: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Dijkstra cloud AI") {
                    Text("Dijkstra sends your prompts, conversation context, file passages, IDE source and tool results through Edsger’s service to DeepSeek to answer requests. DeepSeek processes this information under its own policies. Code and math execute on your device.")
                    Toggle("Allow sharing with Dijkstra", isOn: Binding(get: { settings.sharingConsent }, set: { settings.sharingConsent = $0 }))
                        .accessibilityIdentifier("membership.sharing-consent")
                    Text("Permission is optional and can be withdrawn anytime. When sharing is off, use local AI. Turning it on does not buy a subscription. BYOK has separate provider permissions in Settings → BYOK.")
                    Link("DeepSeek privacy policy", destination: URL(string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html")!)
                    Link("Edsger privacy policy", destination: LegalURLs.privacy)
                }
            }
            .navigationTitle("Cloud privacy").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: back) } }
        }
        .accessibilityIdentifier("membership.cloud-privacy.root")
    }
}

#Preview("Pro · Light") { MembershipScreen(settings: AgentSettingsStore(defaults: UserDefaults(suiteName: "preview.pro.light")!)) {}.preferredColorScheme(.light) }
#Preview("Pro · Dark") { MembershipScreen(settings: AgentSettingsStore(defaults: UserDefaults(suiteName: "preview.pro.dark")!)) {}.preferredColorScheme(.dark) }

#Preview("Pro · Large Text") { MembershipScreen(settings: AgentSettingsStore(defaults: UserDefaults(suiteName: "preview.pro.large")!)) {}.environment(\.dynamicTypeSize, .accessibility3) }
