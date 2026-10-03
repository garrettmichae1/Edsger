import Foundation

@main struct IDEHomeLayoutTests {
    @MainActor static func main() {
        let suite = "edsger.ide.layout.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IDEHomeLayoutStore(defaults: defaults)
        precondition(store.apps == IDEHomeApp.allCases, "First launch preserves the existing apps and languages")
        let unrelatedKey = "lilc.selected.language"
        defaults.set("python", forKey: unrelatedKey)
        precondition(store.move(.lua, to: 0))
        precondition(store.apps.first == .lua && store.apps.count == 10)
        let reopened = IDEHomeLayoutStore(defaults: defaults)
        precondition(reopened.apps == store.apps, "Layout survives a new store/app launch")
        precondition(reopened.move(.lua, to: 9))
        precondition(reopened.apps == IDEHomeApp.allCases, "Forward movement uses the final destination index")
        precondition(reopened.move(.settings, to: 1))
        precondition(Array(reopened.apps.prefix(3)) == [.newFile, .settings, .directory])
        let unchanged = reopened.apps
        precondition(!reopened.move(.settings, to: 1))
        precondition(!reopened.move(.settings, to: -1))
        precondition(!reopened.move(.settings, to: 10))
        precondition(reopened.apps == unchanged, "Invalid or stationary movement cannot change the layout")
        precondition(defaults.string(forKey: unrelatedKey) == "python", "Reordering cannot change the selected language")
        defaults.set(["language-python", "removed-app", "language-python", "settings"], forKey: IDEHomeLayoutStore.preferenceKey)
        let upgraded = IDEHomeLayoutStore(defaults: defaults)
        precondition(Array(upgraded.apps.prefix(2)) == [.python, .settings])
        precondition(Set(upgraded.apps) == Set(IDEHomeApp.allCases) && upgraded.apps.count == 10,
                     "Corrupt/obsolete IDs are ignored and missing/new apps appended exactly once")
        defaults.set("invalid preference", forKey: IDEHomeLayoutStore.preferenceKey)
        precondition(IDEHomeLayoutStore(defaults: defaults).apps == IDEHomeApp.allCases)
        precondition(IDEHomeApp.newFile.accessibilityID == "home-new-file")
        precondition(IDEHomeApp.python.accessibilityID == "language-python")
        precondition(IDEHomeApp.settings.accessibilityID == "Settings")
        precondition(IDEHomeApp.delete.accessibilityID == "Delete")
        print("PASS: default grid, cross-row moves, persistence, final-index semantics, invalid preferences, and stable app identities")
    }
}
