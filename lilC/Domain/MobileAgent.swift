import Foundation

enum EdsgerMembership: String, CaseIterable, Identifiable, Sendable {
    case pro = "lilc.pro.monthly", plus = "lilc.pro.plus.monthly"
    var id: String { rawValue }
    var title: String { self == .pro ? "Edsger Pro" : "Edsger Pro Plus" }
    var monthlyUSD: Int { self == .pro ? 10 : 25 }
    var allowanceNanoUSD: Int64 { self == .pro ? 5_000_000_000 : 15_000_000_000 }
    var allowanceUSD: Int { self == .pro ? 5 : 15 }
}

/// Evaluated only after StoreKit has cryptographically verified a transaction.
enum MembershipAccess {
    static func isActive(expiration: Date?, revocation: Date?, upgraded: Bool, now: Date = Date()) -> Bool {
        guard revocation == nil, !upgraded, let expiration else { return false }
        return expiration > now
    }
}

enum MobileAgentConfiguration {
    static let title = "Dijkstra Super Fast 1.0"
    // Enable only after real Apple sandbox + Cloudflare deployment acceptance.
    // No app-funded provider secret is shipped in this application.
    static let isEnabled = false
    static let baseURL = URL(string: "https://api.lilc.app/v1/mobile-agent")!
    static let allowedHosts = ["api.lilc.app"]
}

struct MobileAgentAllowance: Codable, Equatable, Sendable {
    let remainingNanoUSD: String
    let limitNanoUSD: String
    let renewsAt: Int64
    let available: Bool
    let rateCard: String
    var remaining: Int64 { Int64(remainingNanoUSD) ?? 0 }
    var limit: Int64 { Int64(limitNanoUSD) ?? 0 }
    var renewalDate: Date { Date(timeIntervalSince1970: Double(renewsAt) / 1000) }
    var remainingFraction: Double { limit > 0 ? min(1, max(0, Double(remaining) / Double(limit))) : 0 }
    var isValid: Bool {
        guard let left = Int64(remainingNanoUSD), let total = Int64(limitNanoUSD) else { return false }
        return left >= 0 && total > 0 && left <= total && renewsAt > 0 && !rateCard.isEmpty
    }
}

enum MobileAgentError: LocalizedError, Equatable, TutorRequestFailure {
    case unavailable, membershipRequired, consentRequired, exhausted, rateLimited, busy, invalidResponse
    var usesLocalNext: Bool { self == .exhausted || self == .rateLimited }
    var errorDescription: String? {
        switch self {
        case .unavailable: "Dijkstra is unavailable right now. Try again later or choose an on-device model."
        case .membershipRequired: "An active Edsger membership is needed to use Dijkstra."
        case .consentRequired: "Allow sharing with Dijkstra in Settings → Membership before using it."
        case .exhausted: "Your remaining monthly allowance cannot cover another Dijkstra request. Edsger will handle your next request on this device."
        case .rateLimited: "Dijkstra is busy right now. Edsger will handle your next request on this device."
        case .busy: "Wait for your current Dijkstra request to finish."
        case .invalidResponse: "Dijkstra returned an incomplete response. No new tool actions were executed."
        }
    }
}

enum MobileAgentEndpoint {
    static func validate(_ base: URL, allowedHosts: [String]) throws {
        guard base.scheme == "https", let host = base.host, allowedHosts.contains(host),
              base.user == nil, base.password == nil, base.port == nil, base.query == nil,
              base.fragment == nil, base.path == "/v1/mobile-agent" else { throw MobileAgentError.unavailable }
    }
}
