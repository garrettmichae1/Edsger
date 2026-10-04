import Foundation
import Observation
import StoreKit

/// Verified paid access is separate from the free local editor and agents.
@Observable
@MainActor
final class AgentSettingsStore {
    static let shared = AgentSettingsStore()
    static let monthlyProductID = EdsgerMembership.pro.rawValue

    private let defaults: UserDefaults
    private let enabledKey = "lilc.agent.enabled"
    // Old generic cloud consent never authorizes this newly introduced provider.
    private let consentKey = "edsger.mobile.sharingConsent.v1"
    private let safeguardsKey = "lilc.agent.safeguards"

    var agentsEnabled: Bool {
        didSet { defaults.set(agentsEnabled, forKey: enabledKey) }
    }

    /// Guideline 5.1.2(i): explicit permission before sending prompts/code to third-party AI.
    private(set) var sharingConsentVersion = 0
    var sharingConsent: Bool {
        didSet {
            if sharingConsent != oldValue { sharingConsentVersion += 1 }
            defaults.set(sharingConsent, forKey: consentKey)
        }
    }

    /// Optional protection for users who want to block agent deletion.
    var safeguardsOn: Bool {
        didSet { defaults.set(safeguardsOn, forKey: safeguardsKey) }
    }

    private(set) var products: [String: Product] = [:]
    private(set) var membership: EdsgerMembership?
    private(set) var membershipProof: String?
    var monthlyProduct: Product? { products[Self.monthlyProductID] }
    private var membershipExpiration: Date?
    private(set) var premiumAccessVersion = 0
    var isSubscribed: Bool {
        membership != nil && MembershipAccess.isActive(expiration: membershipExpiration, revocation: nil, upgraded: false)
    }
    private var transactionListener: Task<Void, Never>?
    var storeMessage: String?
    var isPurchasing = false

    var showsAgentSurfaces: Bool {
        AgentRuntimeConfig.surfacesVisibleInThisRelease && agentsEnabled
    }

    var canRunAgents: Bool {
        AgentRuntimeConfig.surfacesVisibleInThisRelease && agentsEnabled
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentsEnabled = defaults.object(forKey: enabledKey) == nil
            ? true : defaults.bool(forKey: enabledKey)
        sharingConsent = defaults.bool(forKey: consentKey)
        if defaults.object(forKey: safeguardsKey) == nil {
            safeguardsOn = true
        } else {
            safeguardsOn = defaults.bool(forKey: safeguardsKey)
        }
    }

    func loadStore() async {
        listenForTransactions()
        do {
            let found = try await Product.products(for: EdsgerMembership.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        } catch { storeMessage = "Membership options could not be loaded. Try again later." }
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var selected: (EdsgerMembership, String, Date)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let plan = EdsgerMembership(rawValue: transaction.productID),
                  MembershipAccess.isActive(expiration: transaction.expirationDate, revocation: transaction.revocationDate, upgraded: transaction.isUpgraded),
                  let expiry = transaction.expirationDate else { continue }
            if selected == nil || plan.allowanceNanoUSD > selected!.0.allowanceNanoUSD {
                selected = (plan, result.jwsRepresentation, expiry)
            }
        }
        if membership != selected?.0 || membershipExpiration != selected?.2 { premiumAccessVersion += 1 }
        membership = selected?.0
        membershipProof = selected?.1
        membershipExpiration = selected?.2
    }

    func purchase(_ plan: EdsgerMembership = .pro) async {
        guard !isPurchasing else { return }
        guard MobileAgentConfiguration.isEnabled else {
            storeMessage = "Dijkstra memberships are coming soon."; return
        }
        guard let product = products[plan.rawValue] else {
            storeMessage = "This membership is unavailable right now. Try again later."; return
        }
        isPurchasing = true; storeMessage = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    storeMessage = "Apple could not verify this purchase. Try Restore purchases."; return
                }
                await transaction.finish()
                await refreshEntitlements()
                await MobileAgentStore.shared.refresh()
            case .userCancelled: break
            case .pending: storeMessage = "Your purchase is awaiting approval."
            @unknown default: break
            }
        } catch { storeMessage = "The purchase could not finish. Try again later." }
    }

    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true; storeMessage = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            storeMessage = isSubscribed ? "Your membership is restored." : "No active membership was found for this Apple account."
        } catch {
            storeMessage = "Purchases could not be restored. Try again later."
        }
    }

    func disableAgentsCompletely() {
        agentsEnabled = false
    }

    private func listenForTransactions() {
        guard transactionListener == nil else { return }
        transactionListener = Task { [weak self] in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                if case .verified(let transaction) = result,
                   EdsgerMembership(rawValue: transaction.productID) != nil {
                    await self?.refreshEntitlements()
                    await transaction.finish()
                    await MobileAgentStore.shared.refresh()
                }
            }
        }
    }
}
