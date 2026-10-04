import Foundation
import Observation

@Observable @MainActor
final class MobileAgentStore {
    static let shared = MobileAgentStore()
    enum Mode: String { case automatic, local, flagship }
    private let defaults: UserDefaults
    private(set) var chatMode: Mode
    private(set) var projectModes: [String: String]
    private(set) var allowance: MobileAgentAllowance?
    private(set) var notice: String?
    private(set) var activeRuns = 0
    private var cooldownUntil = Date.distantPast
    private var isRefreshing = false
    var canChange: Bool { activeRuns == 0 }
    private var settings: AgentSettingsStore { .shared }
    var isEligible: Bool { MobileAgentConfiguration.isEnabled && settings.isSubscribed && settings.sharingConsent }
    var hasAllowance: Bool {
        if let allowance, allowance.renewalDate > Date() { return allowance.available }
        return true // Server, never this hint, authorizes and meters every request.
    }
    var usesCloudForChat: Bool { prefersCloud(chatMode) }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chatMode = Mode(rawValue: defaults.string(forKey: "edsger.mobile.chat") ?? "") ?? .automatic
        projectModes = defaults.dictionary(forKey: "edsger.mobile.projects") as? [String: String] ?? [:]
    }
    private func prefersCloud(_ mode: Mode) -> Bool { mode != .local && isEligible && hasAllowance && cooldownUntil <= Date() }
    private func key(_ language: ProgrammingLanguage, _ project: String) -> String { language.rawValue + ":" + project }
    func usesCloud(language: ProgrammingLanguage, project: String) -> Bool {
        prefersCloud(Mode(rawValue: projectModes[key(language, project)] ?? "") ?? .automatic)
    }
    func selectChat(_ mode: Mode) {
        guard canChange else { return }
        chatMode = mode; defaults.set(mode.rawValue, forKey: "edsger.mobile.chat")
    }
    func selectAgent(_ mode: Mode, language: ProgrammingLanguage, project: String) {
        guard canChange else { return }
        projectModes[key(language, project)] = mode.rawValue
        defaults.set(projectModes, forKey: "edsger.mobile.projects")
    }
    func beginRun() { activeRuns += 1 }
    func endRun() { activeRuns = max(0, activeRuns - 1) }
    func client() -> MobileAgentClient {
        let consentVersion = settings.sharingConsentVersion
        return MobileAgentClient(authorize: { @MainActor in
            guard MobileAgentConfiguration.isEnabled else { throw MobileAgentError.unavailable }
            guard AgentSettingsStore.shared.isSubscribed, let proof = AgentSettingsStore.shared.membershipProof else { throw MobileAgentError.membershipRequired }
            guard AgentSettingsStore.shared.sharingConsent, AgentSettingsStore.shared.sharingConsentVersion == consentVersion else { throw MobileAgentError.consentRequired }
            return proof
        }, didUpdate: { [weak self] snapshot, failure in
            await self?.record(snapshot, failure: failure)
        })
    }
    private func record(_ snapshot: MobileAgentAllowance?, failure: MobileAgentError?) {
        if let snapshot { allowance = snapshot }
        notice = failure?.localizedDescription
        if failure == .rateLimited { cooldownUntil = Date().addingTimeInterval(60) }
        if failure == .membershipRequired { allowance = nil }
    }
    func refresh() async {
        guard isEligible, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do { allowance = try await client().allowance(); notice = nil }
        catch { notice = error.localizedDescription }
    }
}
