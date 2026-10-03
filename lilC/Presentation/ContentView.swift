import Foundation
import StoreKit
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var cWorkspace = LocalCWorkspace()
    @State private var pythonWorkspace = LocalCWorkspace(language: .python)
    @State private var javascriptWorkspace = LocalCWorkspace(language: .javascript)
    @State private var luaWorkspace = LocalCWorkspace(language: .lua)
    @AppStorage("lilc.selected.language") private var selectedLanguage = "c"
    private var localWorkspace: LocalCWorkspace {
        switch selectedLanguage {
        case "python": pythonWorkspace
        case "javascript": javascriptWorkspace
        case "lua": luaWorkspace
        default: cWorkspace
        }
    }
    @State private var appearance = AppearanceStore.shared
    @State private var agentSettings = AgentSettingsStore.shared
    @State private var linuxCourse = LinuxCourseStore.shared
    @State private var activeScreen: AppScreen = .learn
    @State private var tutor = TutorSession()
    @State private var editorReturn: AppScreen = .home
    @State private var filesReturn: AppScreen = .home
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch activeScreen {
            case .home:
                HomeScreen(
                    workspace: localWorkspace,
                    chooseLanguage: { language in
                        guard language != localWorkspace.language else { return }
                        localWorkspace.stopLiveRun()
                        AgentSession.stopActive()
                        selectedLanguage = language.rawValue
                    },
                    startLocal: {
                        editorReturn = .home
                        localWorkspace.browsePath = localWorkspace.currentFile.folderPath
                        activeScreen = .local
                    },
                    openFiles: {
                        filesReturn = .home
                        localWorkspace.browsePath = ""
                        activeScreen = .files
                    },
                    openLearn: {
                        activeScreen = .learn
                    },
                    deleteFile: {
                        localWorkspace.browsePath = ""
                        activeScreen = .deletePicker
                    },
                    openSettings: { activeScreen = .settings }
                )
            case .learn:
                EdsgerScreen(session: tutor, openHome: { activeScreen = .home }, openFiles: {
                    filesReturn = .learn
                    localWorkspace.browsePath = ""
                    activeScreen = .files
                })
                .onAppear { AgentSession.stopActive() }
            case .files:
                FilesScreen(workspace: localWorkspace, title: nil, primaryActionTitle: "OPEN", allowsCreate: true) { file in
                    editorReturn = .home
                    localWorkspace.select(file)
                    activeScreen = .local
                } onFolder: { folder in
                    localWorkspace.enterFolder(folder)
                } back: {
                    if !localWorkspace.goUpFromBrowse() {
                        activeScreen = filesReturn
                    }
                }
            case .deletePicker:
                DeleteFileScreen(workspace: localWorkspace) {
                    activeScreen = .home
                }
            case .settings:
                SettingsScreen(
                    workspace: localWorkspace,
                    appearance: appearance,
                    agentSettings: agentSettings,
                    linuxCourse: linuxCourse
                ) {
                    activeScreen = .home
                }
            case .local:
                LocalModeScreen(workspace: localWorkspace, agentSettings: agentSettings) {
                    activeScreen = editorReturn
                }

            }
        }
        .background(AppPalette.background)
        .toolbar(.hidden, for: .navigationBar)
        .id(appearance.colorWay)
        .lilCPreferredScheme(appearance.colorWay)
        .onAppear { AppHaptics.prepare() }
        }
        .task {
            await linuxCourse.loadStore()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { tutor.flushDrafts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lilCAskForReview)) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(AppReviewPrompt.delaySeconds))
                requestReview()
            }
        }
    }

}

private enum AppScreen {
    case home
    case learn
    case files
    case deletePicker
    case settings
    case local
}

private struct HomeScreen: View {
    let workspace: LocalCWorkspace
    let chooseLanguage: (ProgrammingLanguage) -> Void
    let startLocal: () -> Void
    let openFiles: () -> Void
    let openLearn: () -> Void
    let deleteFile: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 20) {
                        HomeActionButton(title: "New File", detail: "A single \(workspace.language.name) file", symbol: "plus", tint: .blue, accessibilityID: "home-new-file") {
                            workspace.createStandaloneFile()
                            startLocal()
                        }
                        HomeActionButton(title: "Directory", detail: "\(workspace.language.name) files and projects", symbol: "folder.fill", tint: .orange, accessibilityID: "home-directory", action: openFiles)
                        HomeActionButton(title: "Delete", detail: "File or folder", symbol: "trash.fill", tint: .purple, accessibilityID: "Delete", action: deleteFile)
                        HomeActionButton(title: "Editor", detail: workspace.currentFile.name, symbol: "chevron.left.forwardslash.chevron.right", tint: .green, accessibilityID: "home-editor", action: startLocal)
                        HomeActionButton(title: "Chat", detail: "EDSGER", symbol: "bubble.left.and.bubble.right.fill", tint: .indigo, accessibilityID: "home-chat", action: openLearn)
                        HomeActionButton(title: "Settings", detail: "App preferences", symbol: "gearshape.fill", tint: .gray, accessibilityID: "Settings", action: openSettings)
                    }
                    .padding(.vertical, 6)

                    LanguagePicker(language: workspace.language, select: chooseLanguage)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }

        }
        .background(AppPalette.background)
        .foregroundStyle(AppPalette.foreground)
        .buttonStyle(.appHaptic)
    }
}

private struct LanguagePicker: View {
    let language: ProgrammingLanguage
    let select: (ProgrammingLanguage) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 20) {
            ForEach(ProgrammingLanguage.allCases) { item in
                Button { select(item) } label: {
                    VStack(spacing: 11) {
                        LanguageAppIcon(language: item, selected: language == item)
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppPalette.foreground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appHapticSelect)
                .accessibilityLabel("\(item.name) workspace")
                .accessibilityIdentifier("language-\(item.rawValue)")
                .accessibilityAddTraits(language == item ? [.isSelected] : [])
            }
        }
    }
}

private struct LanguageAppIcon: View {
    let language: ProgrammingLanguage
    let selected: Bool

    private var tint: Color {
        switch language {
        case .c: Color(red: 0.12, green: 0.50, blue: 0.89)
        case .python: Color(red: 0.16, green: 0.63, blue: 0.47)
        case .javascript: Color(red: 0.90, green: 0.63, blue: 0.10)
        case .lua: Color(red: 0.42, green: 0.32, blue: 0.78)
        }
    }

    private var initials: String {
        switch language {
        case .c: "C"
        case .python: "Py"
        case .javascript: "JS"
        case .lua: "Lua"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.75), tint, tint.mix(with: .black, by: 0.28)], startPoint: .top, endPoint: .bottom))
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                .frame(width: 136, height: 82)
                .offset(y: -43)
            Text(initials)
                .font(.system(size: language == .lua ? 26 : 33, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 2)
        }
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(tint.mix(with: .black, by: 0.4), lineWidth: 1)
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .padding(1)
        }
        .shadow(color: .black.opacity(0.24), radius: 1, y: 2)
        .shadow(color: tint.opacity(selected ? 0.42 : 0.16), radius: selected ? 9 : 5, y: selected ? 0 : 3)
    }
}

/// Home-only glossy tiles, with the existing actions and accessibility identifiers.
private struct HomeActionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint, tint.mix(with: .black, by: 0.28)], startPoint: .top, endPoint: .bottom))
                    // A curved glass reflection recalls the early iPhone home screen.
                    Ellipse()
                        .fill(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 136, height: 82)
                        .offset(y: -43)
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "plus" ? 37 : 32, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 2)
                }
                .frame(width: 82, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(tint.mix(with: .black, by: 0.4), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        .padding(1)
                }
                .shadow(color: .black.opacity(0.24), radius: 1, y: 2)
                .shadow(color: tint.opacity(0.16), radius: 5, y: 3)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.foreground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.appHaptic)
        .accessibilityLabel("\(title == "New File" ? "New file" : title), \(detail)")
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct FilesScreen: View {
    let workspace: LocalCWorkspace
    var title: String? = nil
    let primaryActionTitle: String
    var allowsCreate: Bool = true
    let select: (LocalCFile) -> Void
    var onFolder: (LocalCFolder) -> Void
    let back: () -> Void
    @State private var searchText = ""
    @State private var showCreateOptions = false
    @State private var showFolderName = false
    @State private var folderName = ""
    @State private var onboarding = OnboardingStore.shared
    @FocusState private var searchFocused: Bool

    private var matches: [LocalBrowserEntry] {
        workspace.searchBrowser(matching: searchText)
    }

    private var heading: String {
        title ?? (workspace.browsePath.isEmpty ? "DIRECTORY" : workspace.browseTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                    if workspace.browsePath.isEmpty {
                        Text("\(workspace.language.name) workspace")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.silver)
                    } else {
                        Text(workspace.browsePath)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.silver)
                    }
                }
                Spacer()
                if allowsCreate {
                    Button {
                        showCreateOptions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(12)
            .background(AppPalette.panel)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppPalette.green)
                TextField("Search files or folders", text: $searchText, prompt: Text("Search files or folders").foregroundStyle(AppPalette.silver))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lilCFieldInk()
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(AppPalette.foreground.opacity(0.75))
                }
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(AppPalette.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if matches.isEmpty {
                        VStack(spacing: 10) {
                            Text("No files found.")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppPalette.foreground)
                            Text(allowsCreate ? (workspace.language == .c ? "Tap + to create a C file, header, or project." : "Tap + to create a \(workspace.language.name) file or project.") : "Try another search.")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppPalette.foreground.opacity(0.72))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        ForEach(matches) { entry in
                            switch entry {
                            case .folder(let folder):
                                FolderBrowserRow(
                                    folder: folder,
                                    subtitle: workspace.browsePath.isEmpty ? "Project folder" : "Folder in this project"
                                ) {
                                    onFolder(folder)
                                }
                                .dropDestination(for: String.self) { paths, _ in
                                    var moved = false
                                    for path in paths {
                                        if let file = workspace.files.first(where: { $0.relativePath == path }) {
                                            moved = workspace.moveFile(file, into: folder.relativePath) || moved
                                        }
                                    }
                                    return moved
                                }
                            case .file(let file):
                                FileBrowserRow(file: file, actionTitle: primaryActionTitle) {
                                    select(file)
                                }
                                .draggable(file.relativePath)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(AppPalette.background)
            .dropDestination(for: String.self) { paths, _ in
                var moved = false
                for path in paths {
                    if let file = workspace.files.first(where: { $0.relativePath == path }) {
                        moved = workspace.moveFile(file, into: workspace.browsePath) || moved
                    }
                }
                return moved
            }

            if allowsCreate, onboarding.needsFilesFolderTip {
                FilesFolderTipBanner {
                    onboarding.dismissFilesFolderTip()
                }
            }
        }
        .background(AppPalette.background)
        .buttonStyle(.appHaptic)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchFocused = false }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
        }
        .confirmationDialog("Create", isPresented: $showCreateOptions, titleVisibility: .visible) {
            Button(workspace.browsePath.isEmpty ? "New standalone \(workspace.language.name) file" : "New \(workspace.language.name) file in this project") {
                workspace.createFile()
                searchText = ""
            }
            Button(workspace.language == .c ? "New Header" : "New \(workspace.language.name) module") {
                workspace.createHeader()
                searchText = ""
            }
            Button(workspace.browsePath.isEmpty ? "New Project" : "New Folder") {
                folderName = ""
                showFolderName = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(workspace.browsePath.isEmpty ? "New Project" : "New Folder", isPresented: $showFolderName) {
            TextField(workspace.browsePath.isEmpty ? "project-name" : "folder-name", text: $folderName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                workspace.createFolder(named: folderName)
                folderName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if workspace.browsePath.isEmpty {
                Text(workspace.language == .c ? "A folder is a project. Open it to add more .c and .h files. IDE → New File still creates a single file at the top level." : "A folder is a \(workspace.language.name) project. Open it to add .\(workspace.language.fileExtension) files and local modules. IDE → New File creates a standalone file.")
            } else {
                Text("Nested folders stay inside this project.")
            }
        }
    }
}

private struct FilesFolderTipBanner: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(OnboardingCopy.filesFolderTip)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(AppPalette.foreground)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppPalette.silver)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appHaptic)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(AppPalette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
        }
        .safeAreaPadding(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OnboardingCopy.filesFolderTip)
    }
}

private struct FolderBrowserRow: View {
    let folder: LocalCFolder
    var subtitle: String = "Project folder"
    var openTitle: String = "OPEN"
    var onDelete: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppPalette.amber)
                        .frame(width: 38, height: 38)
                        .background(AppPalette.panel)
                        .overlay(Rectangle().stroke(AppPalette.line.opacity(0.8)))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(folder.name)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppPalette.foreground)
                        Text("\(folder.relativePath)  *  \(folder.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.foreground.opacity(0.72))
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.foreground.opacity(0.64))
                    }
                    Spacer(minLength: 8)
                    Text(openTitle)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppPalette.green)
                }
            }
            .buttonStyle(.appHaptic)

            if let onDelete {
                Button("DELETE", action: onDelete)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.amber)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(AppPalette.line.opacity(0.7)))
    }
}

private struct DeleteFileScreen: View {
    let workspace: LocalCWorkspace
    let back: () -> Void
    @State private var searchText = ""
    @State private var pendingFile: LocalCFile?
    @State private var pendingFolder: LocalCFolder?
    @FocusState private var searchFocused: Bool

    private var matches: [LocalBrowserEntry] {
        workspace.searchBrowser(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if !workspace.goUpFromBrowse() {
                        back()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                    if !workspace.browsePath.isEmpty {
                        Text(workspace.browsePath)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppPalette.silver)
                    }
                }
                Spacer()
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(12)
            .background(AppPalette.panel)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppPalette.amber)
                TextField("Search files or folders", text: $searchText, prompt: Text("Search files or folders").foregroundStyle(AppPalette.silver))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lilCFieldInk()
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(AppPalette.foreground.opacity(0.75))
                }
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(AppPalette.card)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
            }

            Text("Open a folder to delete files inside it, or delete the folder to remove the whole project.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AppPalette.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppPalette.background)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if matches.isEmpty {
                        VStack(spacing: 10) {
                            Text("Nothing here.")
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppPalette.foreground)
                            Text("Loose files live at the top level. Projects are folders.")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppPalette.foreground.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    } else {
                        ForEach(matches) { entry in
                            switch entry {
                            case .folder(let folder):
                                FolderBrowserRow(
                                    folder: folder,
                                    subtitle: workspace.browsePath.isEmpty ? "Deletes this project if you choose DELETE" : "Nested folder",
                                    openTitle: "OPEN",
                                    onDelete: { pendingFolder = folder }
                                ) {
                                    workspace.enterFolder(folder)
                                    searchText = ""
                                }
                            case .file(let file):
                                FileBrowserRow(file: file, actionTitle: "DELETE", actionTint: AppPalette.amber) {
                                    pendingFile = file
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(AppPalette.background)
        }
        .background(AppPalette.background)
        .buttonStyle(.appHaptic)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchFocused = false }
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
        }
        .alert(
            "Delete \(pendingFile?.name ?? "this file")?",
            isPresented: Binding(
                get: { pendingFile != nil },
                set: { if !$0 { pendingFile = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let file = pendingFile {
                    workspace.delete(file)
                }
                pendingFile = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFile = nil
            }
        } message: {
            Text("This permanently removes \(pendingFile?.relativePath ?? "this file") from this iPhone.")
        }
        .alert(
            "Delete folder \(pendingFolder?.name ?? "")?",
            isPresented: Binding(
                get: { pendingFolder != nil },
                set: { if !$0 { pendingFolder = nil } }
            )
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = pendingFolder {
                    workspace.deleteFolder(folder)
                }
                pendingFolder = nil
            }
            Button("Cancel", role: .cancel) {
                pendingFolder = nil
            }
        } message: {
            let count = pendingFolder.map { workspace.fileCount(in: $0) } ?? 0
            Text("This permanently deletes the folder and \(count) file\(count == 1 ? "" : "s") inside it.")
        }
    }
}

private struct FileBrowserRow: View {
    let file: LocalCFile
    let actionTitle: String
    var actionTint: Color = AppPalette.green
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("." + (file.name as NSString).pathExtension)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.foreground.opacity(0.84))
                    .frame(width: 38, height: 38)
                    .background(AppPalette.panel)
                    .overlay(Rectangle().stroke(AppPalette.line.opacity(0.8)))

                VStack(alignment: .leading, spacing: 5) {
                    Text(file.folderPath.isEmpty ? file.name : file.relativePath)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppPalette.foreground)
                    Text("\(file.updatedAt.formatted(date: .abbreviated, time: .shortened))  *  \(file.sizeText)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppPalette.foreground.opacity(0.72))
                    Text(file.codePreview)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppPalette.foreground.opacity(0.64))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(actionTitle)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(actionTint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(AppPalette.line.opacity(0.7)))
        }
        .buttonStyle(.appHaptic)
    }
}

/// Full-screen OUTPUT console for the whole live run, then back to editor + compact output.
/// Not swipe-driven: swipe cannot collapse a running console (keyboard would cover stdin).
enum OutputChromeExpandPolicy {
    static func expanded(isRunning: Bool) -> Bool {
        isRunning
    }

    /// Swipe is ignored: stay full-screen until the program ends.
    static func expanded(
        afterTranslation _: CGFloat,
        isRunning: Bool,
        currentlyExpanded _: Bool
    ) -> Bool {
        isRunning
    }
}

/// While a program is running, hide the editor chrome and lift the console by the
/// tracked software-keyboard overlap. SwiftUI's keyboard safe area is ignored:
/// it only updates when the keyboard *appears*, so Run with the editor keyboard
/// already up left stdin under the keys.
enum RunConsoleChrome {
    static func hidesEditorChrome(isRunning: Bool) -> Bool { isRunning }

    static func ignoresSystemKeyboardSafeArea(isRunning _: Bool) -> Bool { true }

    static func keyboardOverlapPadding(isRunning: Bool, overlap: CGFloat) -> CGFloat {
        isRunning ? max(0, overlap) : 0
    }

    static func ignoresContainerBottom(padding: CGFloat) -> Bool {
        padding > 80
    }
}

enum SoftwareKeyboardOverlap {
    static func amount(endFrameInScreen: CGRect, windowFrameInScreen: CGRect) -> CGFloat {
        let intersection = endFrameInScreen.intersection(windowFrameInScreen)
        guard !intersection.isNull, intersection.width > 1 else { return 0 }
        return max(0, intersection.height)
    }

    static func amount(from notification: Notification, windowFrameInScreen: CGRect) -> CGFloat {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }
        return amount(endFrameInScreen: end, windowFrameInScreen: windowFrameInScreen)
    }
}

@MainActor
final class SoftwareKeyboard: ObservableObject {
    static let shared = SoftwareKeyboard()

    @Published private(set) var overlap: CGFloat = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardFrameChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged), name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        let next = SoftwareKeyboardOverlap.amount(from: note, windowFrameInScreen: windowFrameInScreen())
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        guard abs(next - overlap) >= 0.5 else { return }
        if duration > 0.01 {
            withAnimation(.easeInOut(duration: duration)) {
                overlap = next
            }
        } else {
            overlap = next
        }
    }

    private func windowFrameInScreen() -> CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
            return window.convert(window.bounds, to: nil)
        }
        return UIScreen.main.bounds
    }
}

private struct RunConsoleKeyboardLift: ViewModifier {
    let isRunning: Bool
    let overlap: CGFloat
    let isAgentVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAgentVisible {
            content
        } else {
            let padding = RunConsoleChrome.keyboardOverlapPadding(isRunning: isRunning, overlap: overlap)
            content
                .padding(.bottom, padding)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .ignoresSafeArea(
                    RunConsoleChrome.ignoresContainerBottom(padding: padding) ? .container : [],
                    edges: .bottom
                )
        }
    }
}

/// Compact running console: output hugs its text, stdin sits directly under it.
enum RunningConsoleLayout {
    static let lineHeight: CGFloat = 20
    static let minLines = 2
    static let maxLines = 6
    static let maxFraction: CGFloat = 0.28

    static func lineCount(in output: String) -> Int {
        if output.isEmpty { return 0 }
        let parts = output.split(separator: "\n", omittingEmptySubsequences: false)
        if output.hasSuffix("\n") {
            return max(parts.count - 1, 0)
        }
        return parts.count
    }

    static func compactOutputHeight(output: String, availableHeight: CGFloat) -> CGFloat {
        let minHeight = CGFloat(minLines) * lineHeight
        let lineCap = CGFloat(maxLines) * lineHeight
        let fractionCap = max(0, availableHeight) * maxFraction
        let maxHeight = max(minHeight, min(lineCap, max(fractionCap, minHeight)))
        let contentHeight = CGFloat(max(lineCount(in: output), minLines)) * lineHeight
        return min(contentHeight, maxHeight)
    }

    static func consoleLayoutPriority(isRunning: Bool, outputExpanded: Bool) -> Double {
        isRunning && outputExpanded ? 1 : 0
    }
}

private enum ConsolePanel {
    case output
    case agent
}

private struct LocalModeScreen: View {
    let workspace: LocalCWorkspace
    let agentSettings: AgentSettingsStore
    let back: () -> Void
    @State private var appearance = AppearanceStore.shared
    @State private var agentSession: AgentSession?
    @State private var selectedPanel: ConsolePanel = .output
    @State private var agentFullScreen = false
    @State private var draftFileName = ""
    @State private var outputExpanded = true
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findEpoch = 0
    @State private var formatEpoch = 0
    @State private var caretJump: CaretJump?
    @State private var showCreateOptions = false
    @State private var containerHeight: CGFloat = 0
    @FocusState private var focusedLocalField: LocalEditorField?
    @ObservedObject private var softwareKeyboard = SoftwareKeyboard.shared

    private var runningCompactOutputHeight: CGFloat? {
        guard workspace.isRunning, outputExpanded, !outputCoversEditor else { return nil }
        return RunningConsoleLayout.compactOutputHeight(
            output: workspace.output,
            availableHeight: max(containerHeight, 400)
        )
    }

    private var hidesEditorChrome: Bool {
        RunConsoleChrome.hidesEditorChrome(isRunning: workspace.isRunning)
            || (selectedPanel == .agent && agentFullScreen && outputExpanded)
    }

    private var findMatches: [NSRange] {
        EditorSearch.nsMatches(in: workspace.currentFile.code, query: findQuery)
    }

    private var outputCoversEditor: Bool {
        (OutputChromeExpandPolicy.expanded(isRunning: workspace.isRunning) && outputExpanded)
            || (selectedPanel == .agent && agentFullScreen && outputExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                }
                .buttonStyle(.appHaptic)
                Text(workspace.editorTitle)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
                Button {
                    workspace.browsePath = workspace.isCurriculumCatalog ? "" : workspace.currentProjectPath
                    showCreateOptions = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(AppPalette.green)
                .accessibilityLabel("New file")
                ShareLink(item: workspace.currentFileURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(AppPalette.green)
                Button(action: toggleFind) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(findVisible ? AppPalette.foreground : AppPalette.green)
                .accessibilityLabel("Find")
                if workspace.language == .c {
                Button("FMT") {
                    formatEpoch += 1
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(AppPalette.green)
                .accessibilityLabel("Format code")
                .accessibilityIdentifier("format-code")
                }
                if workspace.isRunning {
                    Button("STOP") {
                        workspace.stopLiveRun()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(AppPalette.amber, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Button("RUN") {
                        workspace.renameCurrentFile(to: draftFileName)
                        draftFileName = workspace.currentFile.name
                        outputExpanded = true
                        workspace.runCurrentFile()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(AppPalette.green, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(AppPalette.foreground)
            .padding(12)
            .background(AppPalette.panel)

            if !hidesEditorChrome {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(workspace.projectFiles) { file in
                        Button {
                            dismissKeyboard()
                            commitFileName()
                            workspace.select(file)
                            draftFileName = workspace.currentFile.name
                        } label: {
                            Text(file.name)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(file.id == workspace.selectedFileID ? AppPalette.onAccent : AppPalette.foreground)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(file.id == workspace.selectedFileID ? AppPalette.green : AppPalette.card, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppPalette.line.opacity(0.75)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(AppPalette.background)

            HStack(spacing: 8) {
                TextField(workspace.language.starterName, text: $draftFileName, prompt: Text(workspace.language.starterName).foregroundStyle(AppPalette.silver))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lilCFieldInk()
                    .focused($focusedLocalField, equals: .fileName)
                    .onSubmit(commitFileName)
                Button(action: commitFileName) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 30)
                }
                .foregroundStyle(AppPalette.onAccent)
                .background(AppPalette.green, in: RoundedRectangle(cornerRadius: 4))
            }
            .foregroundStyle(AppPalette.green)
            .padding(12)
            .background(AppPalette.card)
            }

            if !hidesEditorChrome, workspace.language == .c, let lesson = FirstHourCurriculum.lesson(relativePath: workspace.currentFile.relativePath) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lesson.kicker)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppPalette.green)
                            .textCase(.uppercase)
                            .tracking(0.4)
                        Text(lesson.goal)
                            .font(.system(size: 15))
                            .foregroundStyle(AppPalette.foreground)
                    }
                    Spacer(minLength: 8)
                    if workspace.showLessonNice {
                        Text("Nice.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppPalette.green)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(AppPalette.panel)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
                }
            }

            if !hidesEditorChrome {
            ZStack(alignment: .top) {
                CCodeEditor(
                    text: Binding(
                        get: { workspace.currentFile.code },
                        set: { workspace.updateCurrentCode($0) }
                    ),
                    fileID: workspace.language.rawValue + ":" + workspace.selectedFileID,
                    language: workspace.language,
                    isFocused: focusedLocalField == .editor,
                    jump: caretJump,
                    findVisible: findVisible,
                    findQuery: findQuery,
                    findIndex: findIndex,
                    findEpoch: findEpoch,
                    formatEpoch: formatEpoch,
                    overlayHeight: findVisible ? 36 : 0,
                    syntaxColoring: appearance.syntaxColoring,
                    onBeginEditing: { focusedLocalField = .editor },
                    onEndEditing: {
                        if focusedLocalField == .editor {
                            focusedLocalField = nil
                        }
                    }
                )
                .background(AppPalette.editor)

                if findVisible {
                    EditorFindBar(
                        query: $findQuery,
                        matchIndex: findIndex,
                        matchCount: findMatches.count,
                        onPrevious: { stepFind(-1) },
                        onNext: { stepFind(1) },
                        onClose: closeFind
                    )
                }
            }
            .frame(minHeight: 0)
            .frame(maxHeight: outputCoversEditor ? 0 : .infinity)
            .layoutPriority(0)
            .clipped()
            .opacity(outputCoversEditor ? 0 : 1)
            .allowsHitTesting(!outputCoversEditor)
            .accessibilityHidden(outputCoversEditor)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("OUTPUT") {
                            selectedPanel = .output
                            outputExpanded = true
                        }
                        .foregroundStyle(selectedPanel == .output ? AppPalette.green : AppPalette.silver)
                        .accessibilityIdentifier("output-tab")
                        if agentSettings.showsAgentSurfaces {
                            Button("AGENT") {
                                selectedPanel = .agent
                                outputExpanded = true
                                if agentSession == nil {
                                    agentSession = AgentSession.shared(workspace: workspace, settings: agentSettings)
                                }
                            }
                            .foregroundStyle(selectedPanel == .agent ? AppPalette.green : AppPalette.silver)
                            .accessibilityIdentifier("agent-tab")
                        }
                        if selectedPanel == .output, workspace.isWaitingForInput {
                            RunStatusBadge(text: "WAITING FOR INPUT", color: AppPalette.amber, pulsing: true)
                                .accessibilityIdentifier("waiting-for-input")
                        } else if selectedPanel == .output, workspace.isRunning {
                            RunStatusBadge(text: "RUNNING", color: AppPalette.green, pulsing: false)
                        } else if selectedPanel == .output, workspace.lastRunNeedsFillIn {
                            if workspace.lastErrorJump != nil {
                                Button(action: jumpToError) {
                                    RunStatusBadge(text: "TODO", color: AppPalette.amber, pulsing: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Jump to the blank")
                            } else {
                                RunStatusBadge(text: "TODO", color: AppPalette.amber, pulsing: false)
                            }
                        } else if selectedPanel == .output, workspace.lastRunFailed {
                            if workspace.lastErrorJump != nil {
                                Button(action: jumpToError) {
                                    RunStatusBadge(text: "ERROR", color: AppPalette.error, pulsing: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Jump to error")
                            } else {
                                RunStatusBadge(text: "ERROR", color: AppPalette.error, pulsing: false)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .contentShape(Rectangle())
                    if selectedPanel == .agent && outputExpanded {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { agentFullScreen.toggle() }
                        } label: {
                            Image(systemName: agentFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(AppPalette.silver)
                        .accessibilityLabel(agentFullScreen ? "Minimize agent" : "Expand agent full screen")
                    }
                    Button {
                        guard selectedPanel == .agent || !workspace.isRunning else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            outputExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(outputExpanded ? "HIDE" : "SHOW")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Image(systemName: outputExpanded ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(AppPalette.silver)
                    }
                    .buttonStyle(.plain)
                }
                if outputExpanded {
                    if selectedPanel == .agent {
                        if let agentSession {
                            AgentConversationView(session: agentSession)
                                .frame(minHeight: 220)
                        }
                    } else {
                        outputBody
                    }
                }
            }
            .padding(12)
            .frame(minHeight: outputExpanded ? 92 : 44, alignment: .top)
            .frame(height: selectedPanel == .agent && outputExpanded && !agentFullScreen ? min(max(containerHeight * 0.44, 270), 420) : nil)
            .frame(maxHeight: outputCoversEditor ? .infinity : nil, alignment: .top)
            .fixedSize(
                horizontal: false,
                vertical: workspace.isRunning && outputExpanded && !outputCoversEditor
            )
            .layoutPriority(RunningConsoleLayout.consoleLayoutPriority(
                isRunning: workspace.isRunning,
                outputExpanded: outputExpanded
            ))
            .background(AppPalette.card)
        }
        .background(AppPalette.background)
        .animation(.easeInOut(duration: 0.18), value: outputCoversEditor)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in
                        containerHeight = height
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if workspace.isRunning && outputExpanded {
                stdinBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.card)
            }
        }
        .modifier(RunConsoleKeyboardLift(
            isRunning: workspace.isRunning,
            overlap: softwareKeyboard.overlap,
            isAgentVisible: selectedPanel == .agent && outputExpanded
        ))
        .onAppear {
            draftFileName = workspace.currentFile.name
        }
        .onChange(of: workspace.selectedFileID) { _, _ in
            draftFileName = workspace.currentFile.name
            clampFindIndex()
        }
        .onChange(of: workspace.isWaitingForInput) { _, waiting in
            if waiting {
                outputExpanded = true
                moveFocusToStdin()
            }
        }
        .onChange(of: workspace.isRunning) { _, running in
            if running {
                outputExpanded = true
            }
        }
        .onChange(of: workspace.lessonCelebrate) { _, celebrate in
            if celebrate == .allDone {
                Task {
                    try? await Task.sleep(for: .seconds(2.4))
                    back()
                }
            }
        }
        .onChange(of: findQuery) { _, _ in
            findIndex = 0
            findEpoch += 1
        }
        .onKeyPress(.escape) {
            if findVisible {
                closeFind()
                return .handled
            }
            return .ignored
        }
        .confirmationDialog("Create", isPresented: $showCreateOptions, titleVisibility: .visible) {
            Button(workspace.browsePath.isEmpty ? "New standalone \(workspace.language.name) file" : "New \(workspace.language.name) file in this project") {
                workspace.createFile()
                draftFileName = workspace.currentFile.name
            }
            Button(workspace.language == .c ? "New Header" : "New \(workspace.language.name) module") {
                workspace.createHeader()
                draftFileName = workspace.currentFile.name
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var stdinBar: some View {
        HStack(spacing: 8) {
            Text(">")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(workspace.isWaitingForInput ? AppPalette.amber : AppPalette.silver)
            TextField(
                workspace.isWaitingForInput ? "type input, then ENTER" : "program input",
                text: Binding(
                    get: { workspace.stdinLine },
                    set: { workspace.stdinLine = $0 }
                ),
                prompt: Text(workspace.isWaitingForInput ? "type input, then ENTER" : "program input")
                    .foregroundStyle(AppPalette.silver)
            )
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lilCFieldInk()
            .submitLabel(.send)
            .focused($focusedLocalField, equals: .stdin)
            .accessibilityIdentifier("program-stdin")
            .onSubmit {
                workspace.submitStdinLine()
                focusedLocalField = .stdin
            }
            Button("ENTER") {
                workspace.submitStdinLine()
                focusedLocalField = .stdin
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(AppPalette.onAccent)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(AppPalette.green, in: RoundedRectangle(cornerRadius: 4))
            Button("EOF") {
                workspace.sendStdinEOF()
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(AppPalette.silver)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            workspace.isWaitingForInput ? AppPalette.amber : AppPalette.line,
                            lineWidth: workspace.isWaitingForInput ? 1.5 : 1
                        )
                )
        )
    }

    @ViewBuilder
    private var outputBody: some View {
        let outputText = Text(workspace.output.isEmpty ? " " : workspace.output)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(AppPalette.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)

        let scroll = ScrollView {
            if workspace.lastErrorJump != nil {
                outputText
                    .contentShape(Rectangle())
                    .onTapGesture(perform: jumpToError)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Jumps to the error line")
            } else {
                outputText
                    .textSelection(.enabled)
            }
        }
        .defaultScrollAnchor(workspace.isRunning ? .bottom : .top)
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("program-output")

        if outputCoversEditor {
            scroll.frame(maxHeight: .infinity, alignment: .top)
        } else if let height = runningCompactOutputHeight {
            scroll.frame(height: height, alignment: .top)
        } else {
            scroll
        }
    }

    private func moveFocusToStdin() {
        DispatchQueue.main.async {
            focusedLocalField = .stdin
        }
    }

    private func dismissKeyboard() {
        focusedLocalField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func commitFileName() {
        workspace.renameCurrentFile(to: draftFileName)
        draftFileName = workspace.currentFile.name
        dismissKeyboard()
    }

    private func toggleFind() {
        if findVisible {
            closeFind()
        } else {
            findVisible = true
            focusedLocalField = .find
        }
    }

    private func closeFind() {
        findVisible = false
        findQuery = ""
        findIndex = 0
        findEpoch += 1
        if focusedLocalField == .find {
            focusedLocalField = nil
        }
    }

    private func stepFind(_ delta: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = (findIndex + delta + count) % count
        findEpoch += 1
    }

    private func clampFindIndex() {
        let count = findMatches.count
        if count == 0 {
            findIndex = 0
        } else if findIndex >= count {
            findIndex = count - 1
        }
    }

    private func jumpToError() {
        guard let jump = workspace.revealErrorJump() else { return }
        outputExpanded = true
        focusedLocalField = .editor
        caretJump = CaretJump(line: jump.line, column: jump.column)
    }
}

private enum LocalEditorField: Hashable {
    case fileName
    case editor
    case stdin
    case find
}

private struct RunStatusBadge: View {
    let text: String
    let color: Color
    let pulsing: Bool
    @State private var isBright = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? (isBright ? 1.0 : 0.35) : 1.0)
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4), lineWidth: 1))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isBright = true
            }
        }
    }
}

private enum AppTypography {
    static func terminal(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
