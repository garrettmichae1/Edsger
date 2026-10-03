import SwiftUI

struct SettingsScreen: View {
    let workspace: LocalCWorkspace
    let appearance: AppearanceStore
    let agentSettings: AgentSettingsStore
    let linuxCourse: LinuxCourseStore
    let back: () -> Void

    @State private var document: LegalDocument?
    @State private var confirmEraseAll = false
    @State private var customKey = ""
    @State private var githubConnected = false
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private var debugLinuxUnlock: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: LinuxCourseStore.debugUnlockKey) },
            set: { value in
                UserDefaults.standard.set(value, forKey: LinuxCourseStore.debugUnlockKey)
                Task { await linuxCourse.refreshEntitlements() }
            }
        )
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            settingsBar

            List {
                appearanceSection
                picoCSection
                filesSection
                linuxCourseSection
                if AgentRuntimeConfig.surfacesVisibleInThisRelease {
                    agentSection
                }
                rateSection
                legalSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(22)
            .environment(\.defaultMinListRowHeight, 44)
            .tint(AppPalette.green)
            .background(AppPalette.background)
        }
        .background(AppPalette.background)
        .sheet(item: $document) { item in
            LegalDocumentView(document: item)
        }
        .task {
            await linuxCourse.loadStore()
            guard AgentRuntimeConfig.surfacesVisibleInThisRelease else { return }
            githubConnected = AgentKeychain.githubToken() != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .lilCGitHubChanged)) { _ in
            guard AgentRuntimeConfig.surfacesVisibleInThisRelease else { return }
            githubConnected = AgentKeychain.githubToken() != nil
        }
        .alert("Erase All Files?", isPresented: $confirmEraseAll) {
            Button("Erase All", role: .destructive) {
                workspace.deleteAllFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every \(workspace.language.name) file in this workspace. A starter file is created.")
        }
    }

    private var settingsBar: some View {
        HStack {
            Button(action: {
                AppHaptics.tap()
                back()
            }) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .accessibilityLabel("Back")

            Text("Settings")
                .font(.headline)
            Spacer()
        }
        .foregroundStyle(AppPalette.foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(AppPalette.panel)
    }

    private var appearanceSection: some View {
        Section {
            ForEach(AppColorWay.allCases) { way in
                Button {
                    appearance.colorWay = way
                } label: {
                    HStack {
                        Text(way.title)
                            .font(.body)
                            .foregroundStyle(AppPalette.foreground)
                        Spacer()
                        if appearance.colorWay == way {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppPalette.green)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appHapticSelect)
                .accessibilityLabel(way.title)
                .accessibilityAddTraits(appearance.colorWay == way ? [.isSelected] : [])
                .listRowBackground(AppPalette.card)
            }
            Toggle(isOn: Binding(
                get: { appearance.syntaxColoring },
                set: { appearance.syntaxColoring = $0 }
            )) {
                Text("Syntax Color")
                    .font(.body)
                    .foregroundStyle(AppPalette.foreground)
            }
            .listRowBackground(AppPalette.card)
            .accessibilityLabel("Syntax Color")
        } header: {
            Text("Appearance")
        } footer: {
            Text("lilC uses Light or Dark everywhere.")
        }
    }

    private var picoCSection: some View {
        Section {
            Text(workspace.language.runtimeExplanation)
                .font(.body)
                .foregroundStyle(AppPalette.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(AppPalette.card)
                .accessibilityLabel("About \(workspace.language.runtimeName)")
        } header: {
            Text(workspace.language.runtimeName)
        }
    }

    private var filesSection: some View {
        Section {
            LabeledContent("On This iPhone") {
                Text("\(workspace.files.count)")
                    .font(.body)
                    .foregroundStyle(AppPalette.silver)
            }
            .font(.body)
            .listRowBackground(AppPalette.card)

            Button("Erase All Files", role: .destructive) {
                AppHaptics.tap()
                confirmEraseAll = true
            }
            .font(.body)
            .foregroundStyle(AppPalette.error)
            .listRowBackground(AppPalette.card)
        } header: {
            Text("Files")
        } footer: {
            Text("Removes every \(workspace.language.name) file in this workspace. A starter file is created.")
        }
    }

    private var linuxCourseSection: some View {
        Section {
            LabeledContent("Status") {
                Text(linuxCourse.isOwned ? "Owned" : "Not owned")
                    .font(.body)
                    .foregroundStyle(AppPalette.silver)
            }
            .font(.body)
            .listRowBackground(AppPalette.card)
            .accessibilityIdentifier("linux-course-status")

            if !linuxCourse.isOwned {
                Button(linuxCourse.isPurchasing ? "Working…" : "Unlock \(linuxCourse.priceText)") {
                    AppHaptics.tap()
                    Task { await linuxCourse.purchase() }
                }
                .font(.body)
                .disabled(linuxCourse.isPurchasing)
                .listRowBackground(AppPalette.card)
                .accessibilityIdentifier("linux-course-unlock")
            }

            Button("Restore Purchases") {
                AppHaptics.tap()
                Task { await linuxCourse.restore() }
            }
            .font(.body)
            .listRowBackground(AppPalette.card)
            .accessibilityIdentifier("linux-course-restore")

            #if DEBUG
            Toggle("DEBUG: unlock without StoreKit", isOn: debugLinuxUnlock)
                .font(.body)
                .listRowBackground(AppPalette.card)
                .tint(AppPalette.green)
                .accessibilityIdentifier("linux-course-debug-unlock")
            #endif
        } header: {
            Text("Linux Course")
        } footer: {
            Text(linuxCourse.storeMessage ?? "A one-time \(linuxCourse.priceText) purchase. C lessons stay free. Study stays on this iPhone.")
        }
    }

    private var rateSection: some View {
        Section {
            if let url = LegalURLs.writeReviewURL() {
                Link(destination: url) {
                    settingsLinkLabel("Write a Review")
                }
                .appHapticTap()
                .listRowBackground(AppPalette.card)
                .accessibilityLabel("Write a Review")
                .accessibilityIdentifier("write-review")
            }
        } footer: {
            Text("Writing a review helps others discover lilC :)")
        }
    }

    private var agentSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { agentSettings.agentsEnabled },
                set: { agentSettings.agentsEnabled = $0 }
            )) {
                Text("Agent Mode")
                    .font(.body)
                    .foregroundStyle(AppPalette.foreground)
            }
            .listRowBackground(AppPalette.card)
            .accessibilityIdentifier("agent-mode-toggle")

            if agentSettings.agentsEnabled {
                Toggle(isOn: Binding(
                    get: { agentSettings.safeguardsOn },
                    set: { agentSettings.safeguardsOn = $0 }
                )) {
                    Text("Block agent deletions")
                        .font(.body)
                        .foregroundStyle(AppPalette.foreground)
                }
                .listRowBackground(AppPalette.card)
            }
        } header: {
            Text("Agent")
        } footer: {
            Text("The bundled model works on this iPhone, including offline. It can edit and run \(workspace.language.name) files in the current project.")
        }
    }

    private var legalSection: some View {
        Section {
            if LegalURLs.extraLegalRowsVisibleInThisRelease {
                Link(destination: LegalURLs.teachers) {
                    settingsLinkLabel("For teachers")
                }
                .appHapticTap()
                .listRowBackground(AppPalette.card)
                Link(destination: LegalURLs.webPlayground) {
                    settingsLinkLabel("Web playground")
                }
                .appHapticTap()
                .listRowBackground(AppPalette.card)
            }
            Link(destination: LegalURLs.privacy) {
                settingsLinkLabel("Privacy Policy")
            }
            .appHapticTap()
            .listRowBackground(AppPalette.card)
            Link(destination: LegalURLs.terms) {
                settingsLinkLabel("Terms of Use")
            }
            .appHapticTap()
            .listRowBackground(AppPalette.card)
            legalRow("Licenses") { document = .licenses }
            if LegalURLs.extraLegalRowsVisibleInThisRelease {
                Link(destination: LegalURLs.support) {
                    settingsLinkLabel("Email Support")
                }
                .appHapticTap()
                .listRowBackground(AppPalette.card)
            }
        } header: {
            Text("Legal")
        } footer: {
            Text("Version \(appVersion)")
        }
    }

    private func legalRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsLinkLabel(title)
        }
        .buttonStyle(.appHaptic)
        .listRowBackground(AppPalette.card)
    }

    private func settingsLinkLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(AppPalette.foreground)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppPalette.silver)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// Learner-facing note. PicoC is an on-device interpreter, not a compiler.
    static let picoCExplanation = """
    PicoC is an interpreter, not a compiler. It runs C on this iPhone. Standard C libraries and extras a desktop compiler provides will not work here.
    """
}

private enum LegalDocument: String, Identifiable {
    case licenses

    var id: String { rawValue }
    var title: String { "Licenses" }

    var body: String {
        """
        PicoC
        Copyright (c) 2009-2011, Zik Saleeba
        Copyright (c) 2015, Joseph Poirier
        All rights reserved.

        Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

        * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
        * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
        * Neither the name of the Zik Saleeba nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.

        lilC source (except third-party components) is licensed under the Apache License 2.0. See LICENSE, NOTICE, and TRADEMARKS.md in the project repository.
        """ + editorLicenses + pythonLicenses
    }

    private var editorLicenses: String {
        guard let url = Bundle.main.url(forResource: "Runestone-LICENSES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return "\n\nCode editor dependencies\n" + text
    }

    private var pythonLicenses: String {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Python-Licenses"),
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return "" }
        return "\n\nLanguage runtimes and dependencies\n" + files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return "\n\n" + file.lastPathComponent + "\n" + text
        }.joined()
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(document.body)
                    .font(.body)
                    .foregroundStyle(AppPalette.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(AppPalette.background)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .lilCPreferredScheme(AppearanceStore.shared.colorWay)
    }
}
