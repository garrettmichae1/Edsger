import SwiftUI

enum EdsgerSection: String, CaseIterable { case chat = "Chat", courses = "Courses" }

struct EdsgerScreen<Courses: View>: View {
    @Bindable var session: TutorSession
    @Binding var section: EdsgerSection
    let openHome: () -> Void
    let openFiles: () -> Void
    @ViewBuilder let courses: () -> Courses
    @Environment(\.colorScheme) private var scheme
    @FocusState private var composerFocused: Bool
    @State private var showsHistory = false
    @State private var showsInfo = false
    @State private var historySearch = ""
    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var surface: Color { scheme == .dark ? Color(white: 0.11) : Color(white: 0.985) }
    private var selection: Color { scheme == .dark ? Color(white: 0.19) : Color(white: 0.93) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if section == .courses {
                courses()
            } else {
                transcript
                composer
            }
        }
        .background(background)
        .foregroundStyle(Color.primary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !composerFocused { navigation }
        }
        .sheet(isPresented: $showsHistory) { history }
        .sheet(isPresented: $showsInfo) {
            EdsgerInfoSheet(background: background, surface: surface, selection: selection)
        }
        .onChange(of: section) { _, value in
            if value == .courses { composerFocused = false }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { composerFocused = false; showsHistory = true } label: {
                ZStack(alignment: .topTrailing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: 15, height: 2.5)
                        Capsule().frame(width: 21, height: 2.5)
                    }
                    Circle().fill(Color.blue).frame(width: 9, height: 9).offset(x: 4, y: -3)
                }
                .frame(width: 48, height: 48)
                .background(surface, in: Circle())
            }
            .accessibilityLabel("Chat history")
            .accessibilityIdentifier("edsger-history")
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(EdsgerSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 17)
                            .frame(height: 42)
                            .background(section == item ? selection : .clear, in: Capsule())
                    }
                    .accessibilityIdentifier("edsger-" + item.rawValue.lowercased())
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(surface, in: Capsule())
            Spacer(minLength: 0)
            Button {
                session.newConversation(); section = .chat; composerFocused = true
            } label: {
                EdsgerChatGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 29, height: 29)
                    .frame(width: 48, height: 48)
                    .background(surface, in: Circle())
            }
            .accessibilityLabel("New EDSGER chat")
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.07), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(session.messages) { message in
                        if message.role == .user {
                            HStack {
                                Spacer(minLength: 38)
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 17).padding(.vertical, 12)
                                    .background(selection, in: RoundedRectangle(cornerRadius: 24))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("EDSGER").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(1)
                                if message.text.isEmpty {
                                    HStack(spacing: 10) {
                                        ProgressView().controlSize(.small)
                                        Text("Thinking on your device…").foregroundStyle(.secondary).font(.subheadline)
                                    }
                                } else {
                                    MathAnswerView(text: message.text)
                                        .textSelection(.enabled)
                                    if !session.isResponding {
                                        Button { UIPasteboard.general.string = message.text } label: {
                                            Image(systemName: "doc.on.doc").font(.system(size: 15))
                                        }
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Copy answer")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error = session.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(.secondary)
                            if !session.messages.isEmpty { Button("Try again") { session.retry() } }
                        }
                        .font(.subheadline)
                    } else if let notice = session.notice {
                        Text(notice).foregroundStyle(.secondary).font(.footnote)
                        if !session.messages.isEmpty { Button("Regenerate response") { session.retry() }.font(.footnote) }
                    }
                    Color.clear.frame(height: 1).id("answer-bottom")
                }
                .font(.system(size: 17))
                .padding(.horizontal, 24)
                .padding(.top, 15)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) { _, _ in reader.scrollTo("answer-bottom", anchor: .bottom) }
            .onChange(of: session.isResponding) { _, value in if !value { reader.scrollTo("answer-bottom", anchor: .bottom) } }
            .onChange(of: composerFocused) { _, value in if value { reader.scrollTo("answer-bottom", anchor: .bottom) } }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 15) {
            if session.messages.isEmpty {
                HStack(spacing: 13) {
                    Text("📚").font(.system(size: 23))
                    Text("What would you like to learn?")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 8)
                .accessibilityLabel("Ask EDSGER about coding or any academic subject")
            }
            VStack(alignment: .leading, spacing: 16) {
                TextField("Ask EDSGER", text: $session.draft, prompt: Text("Ask EDSGER").fontWeight(.semibold).foregroundStyle(.secondary), axis: .vertical)
                    .font(.system(size: 21))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .accessibilityIdentifier("edsger-composer")
                    .padding(.horizontal, 4)
                HStack {
                    Menu {
                        ForEach(["C", "Python", "JavaScript", "Lua", "History", "Physics", "Mathematics"], id: \.self) { topic in
                            Button("Study " + topic) {
                                session.draft = "Help me learn \(topic). Start by asking what I already know."
                                composerFocused = true
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 28, weight: .regular)).frame(width: 36, height: 40)
                    }
                    .accessibilityLabel("Choose a study topic")
                    Spacer()
                    Button { composerFocused = false; showsHistory = true } label: {
                        ZStack {
                            Circle().trim(from: 0.10, to: 0.90).stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(90)).frame(width: 27, height: 27)
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).offset(x: 2, y: 2)
                        }.frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Search chats")
                    Button {
                        if session.isResponding { session.stop() }
                        else { session.send() }
                    } label: {
                        Image(systemName: session.isResponding ? "stop.fill" : "arrow.up")
                            .font(.system(size: session.isResponding ? 18 : 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue.opacity(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isResponding ? 0.45 : 1), in: Circle())
                    }
                    .disabled(!session.isResponding && session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(session.isResponding ? "Stop EDSGER" : "Send to EDSGER")
                    .accessibilityIdentifier("edsger-send")
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(surface, in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.09), radius: 22, y: 8)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var navigation: some View {
        HStack {
            Button { session.stop(); openHome() } label: { Label("IDE", systemImage: "house") }
            Spacer()
            Text("EDSGER · Offline").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button { showsInfo = true } label: { Label("Info", systemImage: "info.circle") }
                .accessibilityLabel("How lilC works offline")
                .accessibilityIdentifier("edsger-info")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(background)
    }

    private var history: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent conversations")
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.8)
                        Text("Pick up where you left off.")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    Button { showsHistory = false; session.stop(); openHome() } label: {
                        historyShortcut("IDE", systemImage: "house")
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ForEach(session.conversations.filter { historySearch.isEmpty || $0.title.localizedCaseInsensitiveContains(historySearch) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(historySearch) } }) { chat in
                    Button {
                        session.select(chat.id); section = .chat; showsHistory = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .background(selection, in: Circle())
                            VStack(alignment: .leading, spacing: 7) {
                                Text(chat.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(chat.updatedAt, style: .date)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(surface, in: RoundedRectangle(cornerRadius: 26))
                        .overlay {
                            RoundedRectangle(cornerRadius: 26)
                                .stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 12, y: 4)
                        .contentShape(RoundedRectangle(cornerRadius: 26))
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions { Button("Delete", role: .destructive) { session.delete(chat.id) } }
                }
            }
            .buttonStyle(.plain)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background)
            .foregroundStyle(Color.primary)
            .searchable(text: $historySearch, prompt: "Search your chats")
            .navigationTitle("EDSGER")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsHistory = false }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func historyShortcut(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(surface, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(scheme == .dark ? 0.08 : 1), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 12, y: 4)
    }

}

private struct EdsgerInfoSheet: View {
    let background: Color
    let surface: Color
    let selection: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var mode: Mode = .chat
    @State private var step = 0

    private enum Mode: String, CaseIterable {
        case chat = "Chat", agent = "Agent"

        var title: String { self == .chat ? "Learn through conversation." : "Build inside your IDE." }
        var detail: String {
            self == .chat
                ? "Explore coding, math, science, and more with EDSGER. Ask follow-ups and work through ideas at your pace."
                : "Ask the coding agent to read, create, and edit project files, run code, and inspect output in your IDE."
        }
        var steps: [String] { self == .chat ? ["Ask", "Explore", "Practice"] : ["Request", "Work", "Review"] }
        var examples: [String] {
            self == .chat
                ? ["“Explain Python loops with a small example.”", "EDSGER explains in chat. Ask it to slow down, go deeper, or show another example.", "Try the example in the IDE. Chat can show code, but it cannot read, change, or run your files."]
                : ["“Add input validation to this program.”", "The agent inspects project code and uses local tools to make changes and run supported code.", "Inspect the changes and output in your IDE. You can stop the agent; deletion is blocked while safeguards are on."]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color.blue)
                            .frame(width: 60, height: 60)
                            .background(surface, in: Circle())
                            .accessibilityHidden(true)
                        Text("On your device.\nOn your terms.")
                            .font(.system(size: 32, weight: .semibold))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The AI is built into lilC. Chat and coding-agent replies are generated on your device, without sending prompts to a cloud AI service.")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 0) {
                            ForEach(Mode.allCases, id: \.self) { item in
                                Button { mode = item; step = 0 } label: {
                                    Text(item.rawValue)
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(mode == item ? selection : .clear, in: Capsule())
                                }
                                .accessibilityAddTraits(mode == item ? [.isSelected] : [])
                                .accessibilityIdentifier("edsger-info-" + item.rawValue.lowercased())
                            }
                        }
                        .padding(4)
                        .background(background, in: Capsule())
                        VStack(alignment: .leading, spacing: 9) {
                            Text(mode.title).font(.system(size: 22, weight: .semibold))
                            Text(mode.detail).font(.system(size: 16)).foregroundStyle(.secondary)
                        }
                        Text("TAP THROUGH AN EXAMPLE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(0..<3) { index in
                                Button { step = index } label: {
                                    VStack(spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(step == index ? Color.white : Color.primary)
                                            .frame(width: 36, height: 36)
                                            .background(step == index ? Color.blue : selection, in: Circle())
                                        Text(mode.steps[index])
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Step \(index + 1): \(mode.steps[index])")
                                .accessibilityAddTraits(step == index ? [.isSelected] : [])
                            }
                        }
                        Text(mode.examples[step])
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(background, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(20)
                    .background(surface, in: RoundedRectangle(cornerRadius: 30))
                    .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(scheme == .dark ? 0.08 : 1)))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 18, y: 6)

                    VStack(alignment: .leading, spacing: 0) {
                        infoAnswer("What works without Wi-Fi?", text: "Once lilC is installed, the bundled AI can answer in Chat and work on code in Agent mode without an internet connection or a separate model download. Lessons and supported code execution are local too.")
                        Divider().padding(.vertical, 16)
                        infoAnswer("What makes this different?", text: "Your device does the AI work. Chat and Agent do not need a cloud AI account or API key. Your conversations are saved locally, and the agent works with files in your IDE. Device backups and any files you choose to share follow your normal iOS settings.")
                        Divider().padding(.vertical, 16)
                        infoAnswer("What should I expect?", text: "Local AI can make mistakes and has no live web access. It is best used for focused questions and small coding tasks. Speed depends on your device and the size of the request; the first reply may take longer while the model loads.")
                    }
                    .padding(20)
                    .background(surface, in: RoundedRectangle(cornerRadius: 26))
                    Text("Your files live in the IDE. Open IDE from Chat to manage projects and code.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(background)
            .foregroundStyle(Color.primary)
            .buttonStyle(.plain)
            .navigationTitle("Made to work offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }

    private func infoAnswer(_ title: String, text: String) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        } label: {
            Text(title).font(.system(size: 16, weight: .semibold))
                .padding(.vertical, 6)
        }
        .tint(.primary)
    }
}

private struct EdsgerChatGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) * 0.43
        func point(_ degrees: Double) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        var path = Path()
        path.addArc(center: center, radius: r, startAngle: .degrees(220), endAngle: .degrees(315), clockwise: false)
        path.move(to: point(340))
        path.addArc(center: center, radius: r, startAngle: .degrees(340), endAngle: .degrees(80), clockwise: false)
        path.move(to: point(105))
        path.addLine(to: CGPoint(x: rect.minX + 7, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 10))
        path.addArc(center: center, radius: r, startAngle: .degrees(155), endAngle: .degrees(195), clockwise: false)
        return path
    }
}
