import Foundation
import Observation

@Observable @MainActor
final class BYOKStore {
    static let shared = BYOKStore()
    private(set) var configurations: [String: BYOKConfiguration]
    private(set) var chatChoice: BYOKChoice?
    private(set) var agentDefault: BYOKChoice?
    private(set) var projectChoices: [String: BYOKChoice]
    private(set) var localProjects: Set<String>
    private(set) var isConfiguring = false
    private(set) var activeRuns = 0
    var canConfigure: Bool { !isConfiguring && activeRuns == 0 }
    private let defaults: UserDefaults
    private let credentials: any ProviderCredentialStoring
    private let connection: any BYOKConnecting
    private var consentVersions: [BYOKProvider: Int] = [:]
    private static let configurationKey = "edsger.byok.configurations"

    init(defaults: UserDefaults = .standard, credentials: any ProviderCredentialStoring = ProviderKeychain(), connection: any BYOKConnecting = BYOKProviderClient()) {
        self.defaults = defaults; self.credentials = credentials; self.connection = connection
        configurations = Self.read([String: BYOKConfiguration].self, Self.configurationKey, defaults) ?? [:]
        chatChoice = Self.read(BYOKChoice.self, "edsger.byok.chat", defaults)
        agentDefault = Self.read(BYOKChoice.self, "edsger.byok.agent.default", defaults)
        projectChoices = Self.read([String: BYOKChoice].self, "edsger.byok.agent.projects", defaults) ?? [:]
        localProjects = Self.read(Set<String>.self, "edsger.byok.agent.local-projects", defaults) ?? []
    }
    var choices: [BYOKChoice] {
        BYOKProvider.allCases.flatMap { provider -> [BYOKChoice] in
            guard let config = configurations[provider.rawValue] else { return [] }
            return config.models.filter { config.verifiedModelIDs.contains($0.id) }
                .map { .init(provider: provider, modelID: $0.id) }
        }
    }
    func title(_ choice: BYOKChoice) -> String {
        let name = configurations[choice.provider.rawValue]?.models.first(where: { $0.id == choice.modelID })?.name ?? choice.modelID
        return choice.provider.title + " · " + name
    }
    func requireConsent(_ provider: BYOKProvider) throws {
        guard let config = configurations[provider.rawValue] else { throw BYOKError.missingKey }
        guard config.sharingConsent else { throw BYOKError.consentRequired }
    }
    func setConsent(_ value: Bool, provider: BYOKProvider) {
        consentVersions[provider, default: 0] += 1
        guard configurations[provider.rawValue] != nil else { return }
        configurations[provider.rawValue]?.sharingConsent = value; persist()
    }
    func key(provider: BYOKProvider, draft: String) throws -> String {
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try BYOKSecretValidation.clean(draft) }
        guard let key = try credentials.read(provider) else { throw BYOKError.missingKey }
        return key
    }
    func loadModels(provider: BYOKProvider, draftKey: String, consent: Bool) async throws -> [BYOKModel] {
        guard canConfigure else { throw BYOKError.busy }
        guard consent else { throw BYOKError.consentRequired }
        let key = try key(provider: provider, draft: draftKey)
        isConfiguring = true; defer { isConfiguring = false }
        let models = try await connection.models(provider: provider, key: key)
        try Task.checkCancellation()
        guard !models.isEmpty else { throw BYOKError.providerCode("unsupported_model") }
        return models
    }
    func save(provider: BYOKProvider, draftKey: String, modelID: String, models: [BYOKModel], consent: Bool) async throws {
        guard canConfigure else { throw BYOKError.busy }
        guard consent else { throw BYOKError.consentRequired }
        guard models.contains(where: { $0.id == modelID }) else { throw BYOKError.providerCode("unsupported_model") }
        let key = try key(provider: provider, draft: draftKey)
        isConfiguring = true; defer { isConfiguring = false }
        let consentVersion = consentVersions[provider, default: 0]
        try await connection.verify(choice: .init(provider: provider, modelID: modelID), key: key)
        try Task.checkCancellation()
        guard consentVersions[provider, default: 0] == consentVersion else { throw BYOKError.consentRequired }
        let sameCredential = try credentials.read(provider) == key
        var verified = sameCredential ? configurations[provider.rawValue]?.verifiedModelIDs ?? [] : []
        verified.insert(modelID)
        try credentials.save(key, for: provider)
        configurations[provider.rawValue] = .init(models: models, modelID: modelID, verifiedModelIDs: verified, sharingConsent: true, verifiedAt: Date())
        if !sameCredential {
            if chatChoice?.provider == provider { chatChoice = .init(provider: provider, modelID: modelID) }
            if agentDefault?.provider == provider { agentDefault = .init(provider: provider, modelID: modelID) }
            for project in Array(projectChoices.keys) where projectChoices[project]?.provider == provider {
                projectChoices[project] = .init(provider: provider, modelID: modelID)
            }
        }
        persist()
    }
    func remove(_ provider: BYOKProvider) throws {
        guard canConfigure else { throw BYOKError.busy }
        try credentials.remove(provider)
        configurations.removeValue(forKey: provider.rawValue)
        // Keep paying-source choices; a missing key must not trigger fallback.
        persist()
    }
    func selectChat(_ choice: BYOKChoice?) {
        guard canConfigure else { return }
        chatChoice = choice; persist()
    }
    func selectAgentDefault(_ choice: BYOKChoice?) {
        guard canConfigure else { return }
        agentDefault = choice; persist()
    }
    func agentChoice(language: ProgrammingLanguage, project: String) -> BYOKChoice? {
        let scope = projectKey(language: language, project: project)
        return localProjects.contains(scope) ? nil : projectChoices[scope] ?? agentDefault
    }
    func selectAgent(_ choice: BYOKChoice?, language: ProgrammingLanguage, project: String) {
        guard canConfigure else { return }
        let scope = projectKey(language: language, project: project)
        if let choice { projectChoices[scope] = choice; localProjects.remove(scope) }
        else { projectChoices.removeValue(forKey: scope); localProjects.insert(scope) }
        persist()
    }
    func client(for choice: BYOKChoice) throws -> BYOKAgentClient {
        guard !isConfiguring else { throw BYOKError.busy }
        try requireConsent(choice.provider)
        guard configurations[choice.provider.rawValue]?.verifiedModelIDs.contains(choice.modelID) == true else { throw BYOKError.missingKey }
        guard let key = try credentials.read(choice.provider) else { throw BYOKError.missingKey }
        return .init(choice: choice, key: key, connection: connection, authorize: { try await self.requireConsent(choice.provider) })
    }
    func beginRun() throws {
        guard !isConfiguring else { throw BYOKError.busy }
        activeRuns += 1
    }
    func endRun() { activeRuns = max(0, activeRuns - 1) }
    private func projectKey(language: ProgrammingLanguage, project: String) -> String { language.rawValue + ":" + project }
    private static func read<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func persist() {
        // Metadata only. These values must never contain API keys.
        func write<T: Encodable>(_ value: T, _ key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
        write(configurations, Self.configurationKey); write(chatChoice, "edsger.byok.chat")
        write(agentDefault, "edsger.byok.agent.default"); write(projectChoices, "edsger.byok.agent.projects")
        write(localProjects, "edsger.byok.agent.local-projects")
    }
}
