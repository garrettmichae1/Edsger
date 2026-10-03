import SwiftUI

struct SettingsScreen: View {
    let workspace: LocalCWorkspace
    let appearance: AppearanceStore
    let agentSettings: AgentSettingsStore
    let back: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var document: LegalDocument?
    @State private var confirmEraseAll = false
    @State private var showsTour = false

    // Match the quiet surfaces used by Chat and its Info sheet.
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }
    private var selection: Color { scheme == .dark ? Color(white: 0.19) : Color(white: 0.93) }
    private var outline: Color { Color.primary.opacity(scheme == .dark ? 0.09 : 0.06) }
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsBar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    appearanceSection
                    editorSection
                    if AgentRuntimeConfig.surfacesVisibleInThisRelease {
                        agentSection
                    }
                    workspaceSection
                    aboutSection
                    VStack(spacing: 5) {
                        Text("Edsger").font(.footnote.weight(.semibold))
                        Text("Version \(appVersion)").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("settings.scroll")
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(Color.primary)
        .tint(.blue)
        .lilCPreferredScheme(appearance.colorWay)
        .accessibilityIdentifier("settings.root")
        .sheet(item: $document) { item in
            LegalDocumentView(document: item)
        }
        .fullScreenCover(isPresented: $showsTour) {
            OnboardingView(isReplay: true) { showsTour = false }
        }
        .alert("Erase \(workspace.language.name) workspace?", isPresented: $confirmEraseAll) {
            Button("Erase files", role: .destructive) {
                guard !workspace.isRunning else { return }
                workspace.deleteAllFiles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all files and folders in your \(workspace.language.name) workspace, including its projects, and creates a starter file. Other language workspaces are kept.")
        }
    }

    private var settingsBar: some View {
        HStack(spacing: 16) {
            Button {
                AppHaptics.tap()
                back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("settings.back")
            Text("Settings")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(background)
    }

    private var appearanceSection: some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return settingsGroup("Appearance") {
            layout {
                ForEach(AppColorWay.allCases) { way in
                    appearanceChoice(way)
                }
            }
            .padding(16)
        }
    }

    private func appearanceChoice(_ way: AppColorWay) -> some View {
        let selected = appearance.colorWay == way
        return Button {
            appearance.colorWay = way
        } label: {
            VStack(spacing: 12) {
                appearancePreview(way)
                HStack(spacing: 8) {
                    Text(way.title).font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.blue : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? Color.blue : outline, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.appHapticSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(way.title + " appearance")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("settings.appearance." + way.rawValue)
    }

    private func appearancePreview(_ way: AppColorWay) -> some View {
        let dark = way == .dark
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                Spacer()
                Capsule().fill(dark ? Color(white: 0.3) : Color(white: 0.82))
                    .frame(width: 24, height: 4)
            }
            HStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 8)
                    .fill(dark ? Color(white: 0.25) : Color(white: 0.9))
                    .frame(width: 44, height: 18)
            }
            Capsule().fill(dark ? Color(white: 0.7) : Color(white: 0.4))
                .frame(maxWidth: 68).frame(height: 4)
            Capsule().fill(dark ? Color(white: 0.35) : Color(white: 0.8))
                .frame(maxWidth: 44).frame(height: 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(dark ? Color(white: 0.075) : Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.18)))
        .accessibilityHidden(true)
    }

    private var editorSection: some View {
        settingsGroup("Editor") {
            Toggle(isOn: Binding(
                get: { appearance.syntaxColoring },
                set: { appearance.syntaxColoring = $0 }
            )) {
                rowLabel("Syntax highlighting", symbol: "curlybraces")
            }
            .padding(18)
            .accessibilityIdentifier("settings.syntax-highlighting")
            rowDivider
            DisclosureGroup {
                Text(runtimeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityIdentifier("settings.runtime-summary")
            } label: {
                rowLabel("Runtime", symbol: "cpu", detail: "\(workspace.language.name) · \(workspace.language.runtimeName)")
            }
            .padding(18)
            .accessibilityIdentifier("settings.runtime")
        }
    }

    private var runtimeSummary: String {
        switch workspace.language {
        case .c: "C runs locally with PicoC. External C libraries and some desktop compiler features are unavailable."
        case .python: "Python runs locally with the bundled standard library. Installing packages with pip is unavailable."
        case .javascript: "JavaScript runs locally with JavaScriptCore. Node.js, npm, and browser APIs are unavailable."
        case .lua: "Lua runs locally with project modules. LuaRocks and native modules are unavailable."
        }
    }

    private var agentSection: some View {
        settingsGroup("Agent") {
            Toggle(isOn: Binding(
                get: { agentSettings.agentsEnabled },
                set: { agentSettings.agentsEnabled = $0 }
            )) {
                rowLabel("Agent mode", symbol: "sparkles", detail: "On-device help inside the IDE.")
            }
            .padding(18)
            .accessibilityIdentifier("agent-mode-toggle")
            if agentSettings.agentsEnabled {
                rowDivider
                Toggle(isOn: Binding(
                    get: { agentSettings.safeguardsOn },
                    set: { agentSettings.safeguardsOn = $0 }
                )) {
                    rowLabel("Protect files from deletion", symbol: "hand.raised", detail: "Blocks the agent's delete action. Edits are still allowed.")
                }
                .padding(18)
                .accessibilityIdentifier("settings.agent-safeguards")
            }
        }
    }

    private var workspaceSection: some View {
        settingsGroup("Workspace") {
            HStack(spacing: 12) {
                rowLabel(workspace.language.name + " files", symbol: "folder", detail: "Stored on this device")
                Spacer(minLength: 0)
                Text(workspace.files.count.formatted())
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .accessibilityElement(children: .combine)
            rowDivider
            Button(role: .destructive) {
                AppHaptics.tap()
                confirmEraseAll = true
            } label: {
                rowLabel("Erase workspace files", symbol: "trash",
                         detail: workspace.isRunning ? "Stop the program before erasing files." : nil)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(workspace.isRunning)
            .opacity(workspace.isRunning ? 0.45 : 1)
            .accessibilityIdentifier("settings.erase-files")
        }
    }

    private var aboutSection: some View {
        settingsGroup("About Edsger") {
            Button { showsTour = true } label: {
                navigationRow("Take the tour", symbol: "rectangle.stack")
            }
            .accessibilityIdentifier("settings.tour")
            if let url = LegalURLs.writeReviewURL() {
                rowDivider
                Link(destination: url) { navigationRow("Write a review", symbol: "star") }
                    .accessibilityIdentifier("write-review")
            }
            rowDivider
            Link(destination: LegalURLs.privacy) { navigationRow("Privacy policy", symbol: "lock") }
            rowDivider
            Link(destination: LegalURLs.terms) { navigationRow("Terms of use", symbol: "doc.text") }
            rowDivider
            Button { document = .licenses } label: {
                navigationRow("Open-source licenses", symbol: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("settings.licenses")
            if LegalURLs.extraLegalRowsVisibleInThisRelease {
                rowDivider
                Link(destination: LegalURLs.teachers) { navigationRow("For teachers", symbol: "person.2") }
                rowDivider
                Link(destination: LegalURLs.webPlayground) { navigationRow("Web playground", symbol: "safari") }
                rowDivider
                Link(destination: LegalURLs.support) { navigationRow("Email support", symbol: "envelope") }
            }
        }
        .buttonStyle(.appHaptic)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(surface, in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(outline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 26))
        }
    }

    private var rowDivider: some View {
        Divider().overlay(outline).padding(.leading, 66).padding(.trailing, 18)
    }

    private func rowLabel(_ title: String, symbol: String, detail: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 36, height: 36)
                .background(selection, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func navigationRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            rowLabel(title, symbol: symbol)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.primary)
        .padding(18)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
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
