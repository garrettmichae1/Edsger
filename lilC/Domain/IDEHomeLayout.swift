import Foundation
import Observation

/// Stable identities keep layout independent of titles, language selection and file names.
enum IDEHomeApp: String, CaseIterable, Identifiable, Sendable {
    case newFile = "new-file", directory, delete, editor, chat, settings
    case c = "language-c", python = "language-python", javascript = "language-javascript", lua = "language-lua"
    var id: String { rawValue }
    var language: ProgrammingLanguage? {
        switch self {
        case .c: .c
        case .python: .python
        case .javascript: .javascript
        case .lua: .lua
        default: nil
        }
    }
    var title: String {
        switch self {
        case .newFile: "New File"
        case .directory: "Directory"
        case .delete: "Delete"
        case .editor: "Editor"
        case .chat: "Chat"
        case .settings: "Settings"
        default: language?.name ?? ""
        }
    }
    var accessibilityID: String {
        switch self {
        case .delete: "Delete"
        case .settings: "Settings"
        default: language == nil ? "home-" + rawValue : rawValue
        }
    }
}

/// This preference changes presentation only; it never touches workspaces or files.
@Observable @MainActor
final class IDEHomeLayoutStore {
    static let preferenceKey = "edsger.ide.home.order.v1"
    private(set) var apps: [IDEHomeApp]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apps = Self.normalized(defaults.stringArray(forKey: Self.preferenceKey) ?? [])
    }

    /// Retain known unique IDs, discard obsolete IDs, append newly introduced apps.
    static func normalized(_ identifiers: [String]) -> [IDEHomeApp] {
        var seen = Set<IDEHomeApp>()
        let saved = identifiers.compactMap(IDEHomeApp.init(rawValue:)).filter { seen.insert($0).inserted }
        return saved + IDEHomeApp.allCases.filter { !seen.contains($0) }
    }

    /// Destination is the final index, matching UICollectionView's movement callback.
    @discardableResult
    func move(_ app: IDEHomeApp, to destination: Int) -> Bool {
        guard apps.indices.contains(destination), let source = apps.firstIndex(of: app), source != destination else { return false }
        var updated = apps
        updated.remove(at: source)
        updated.insert(app, at: destination)
        apps = updated
        defaults.set(updated.map(\.rawValue), forKey: Self.preferenceKey)
        return true
    }
}
