import SwiftUI
import UIKit

/// Presentation only: first launch and Settings replay keep their existing callbacks.
struct OnboardingView: View {
    let isReplay: Bool
    let finish: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var phase: Phase = .title
    @State private var titleVisible = false
    @State private var isPaused = false
    @State private var readsIntroduction = false
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning
    @State private var hasFinished = false

    private enum Phase: String { case title, crawl, closing }
    private var staticPresentation: Bool {
        reduceMotion || voiceOver || typeSize.isAccessibilitySize || readsIntroduction
    }
    private var playbackKey: String {
        "\(phase.rawValue)-\(scenePhase == .active)-\(isPaused)-\(staticPresentation)"
    }

    init(isReplay: Bool = false, finish: @escaping () -> Void) {
        self.isReplay = isReplay
        self.finish = finish
    }

    var body: some View {
        ZStack {
            IntroPalette.background.ignoresSafeArea()
            backdrop.accessibilityHidden(true)
            VStack(spacing: 0) {
                controls
                if staticPresentation {
                    readableIntroduction
                } else {
                    cinematicIntroduction
                }
            }
        }
        .foregroundStyle(IntroPalette.ink)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
        .task(id: playbackKey) {
            guard !staticPresentation, !isPaused, scenePhase == .active else { return }
            do {
                switch phase {
                case .title:
                    withAnimation(.easeOut(duration: 1.2)) { titleVisible = true }
                    try await Task.sleep(for: .seconds(3.8))
                    try Task.checkCancellation()
                    withAnimation(.easeInOut(duration: 0.65)) { phase = .crawl }
                case .crawl:
                    break // UIKit drives the crawl without per-frame SwiftUI updates.
                case .closing:
                    try await Task.sleep(for: .seconds(2.5))
                    try Task.checkCancellation()
                    complete()
                }
            } catch { /* Changing presentation or leaving the app cancels this stage. */ }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOver = UIAccessibility.isVoiceOverRunning
        }
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                RadialGradient(colors: [IntroPalette.glow.opacity(0.45), .clear],
                               center: .bottom, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.8)
                Path { path in
                    for index in 0..<28 {
                        let x = CGFloat((index * 37 + 11) % 101) / 100 * geometry.size.width
                        let y = CGFloat((index * 61 + 7) % 103) / 102 * geometry.size.height
                        let size: CGFloat = index.isMultiple(of: 5) ? 2 : 1
                        path.addEllipse(in: CGRect(x: x, y: y, width: size, height: size))
                    }
                }
                .fill(IntroPalette.ink.opacity(0.22))
            }
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if !staticPresentation {
                Button {
                    isPaused.toggle()
                } label: {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding.pause")
                Button { readsIntroduction = true } label: {
                    Text("Read intro").frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding.read")
            }
            Spacer(minLength: 0)
            Button(action: complete) {
                Text(isReplay ? "Done" : "Skip").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityIdentifier("onboarding.skip")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(IntroPalette.secondary)
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var cinematicIntroduction: some View {
        GeometryReader { geometry in
            ZStack {
                if phase == .crawl {
                    CinematicCrawl(isPaused: isPaused || scenePhase != .active) {
                        guard phase == .crawl, !hasFinished else { return }
                        withAnimation(.easeInOut(duration: 0.7)) { phase = .closing }
                    }
                    .padding(.horizontal, 28)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
                if phase == .title {
                    VStack(spacing: 18) {
                        Text("EDSGER")
                            .font(.system(size: min(46, geometry.size.width * 0.115), weight: .bold))
                            .fontWidth(.expanded)
                            .tracking(5)
                            .accessibilityIdentifier("onboarding.headline")
                        Text("LEARN. CODE. CREATE.")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(IntroPalette.accent)
                    }
                    .opacity(titleVisible ? 1 : 0)
                    .scaleEffect(titleVisible ? 1 : 1.06)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                if phase == .closing {
                    VStack(spacing: 18) {
                        Text("Welcome to Edsger.")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(IntroPalette.secondary)
                        Text("What will you build?")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(IntroPalette.accent)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var readableIntroduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(IntroScript.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.system(.headline, design: .monospaced).weight(.semibold))
                            .tracking(1.5)
                            .foregroundStyle(IntroPalette.accent)
                            .accessibilityAddTraits(.isHeader)
                        Text(section.body)
                            .font(.title3.weight(.medium))
                            .lineSpacing(7)
                    }
                }
                Text("What will you build?")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(IntroPalette.accent)
            }
            .frame(maxWidth: 540, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .accessibilityIdentifier("onboarding.scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(isReplay ? "Done" : "Let’s go", action: complete)
                .font(.body.weight(.semibold))
                .foregroundStyle(IntroPalette.background)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(IntroPalette.accent, in: RoundedRectangle(cornerRadius: 18))
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.primary")
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(IntroPalette.background)
        }
    }

    private func complete() {
        guard !hasFinished else { return }
        hasFinished = true
        finish()
    }
}

private enum IntroPalette {
    static let background = Color(red: 7 / 255, green: 10 / 255, blue: 16 / 255)
    static let ink = Color(red: 243 / 255, green: 240 / 255, blue: 232 / 255)
    static let accent = Color(red: 123 / 255, green: 200 / 255, blue: 255 / 255)
    static let secondary = Color(red: 173 / 255, green: 184 / 255, blue: 200 / 255)
    static let glow = Color(red: 22 / 255, green: 58 / 255, blue: 99 / 255)
}

private enum IntroScript {
    struct Section: Identifiable, Sendable {
        let title: String
        let body: String
        var id: String { title }
    }
    static let sections = [
        Section(title: "WELCOME TO EDSGER.", body: "Unlimited offline access to AI.\nBuilt to help you learn, code, and create."),
        Section(title: "CODE ON YOUR TERMS.", body: "Write and run C, Python, Lua, and JavaScript.\n\nWork with a coding agent that can inspect your project, edit files, and run supported code.\n\nAll on your device."),
        Section(title: "KEEP THE CONVERSATION GOING.", body: "Explore ideas with the built-in Edsger chat models.\nAsk questions. Work through problems.\nKeep going as long as you want.\n\nNo connection required.\nNo daily message limits.\nNo waiting for a reset."),
        Section(title: "GO FURTHER WITH PRO.", body: "Get access to Dijkstra Super Fast 1.0 for more capable cloud AI.\n\nOr bring your own API key with BYOK.\n\nChoose Pro or Pro Plus, with two usage tiers to fit how you work."),
        Section(title: "BUILT FOR PEOPLE LIKE YOU.", body: "Academics.\nDevelopers.\nPeople who value privacy.\n\nAnd people who think Silicon Valley sucks.")
    ]
}

/// One native animation moves a laid-out text container; no SwiftUI frame timer.
private struct CinematicCrawl: UIViewRepresentable {
    let isPaused: Bool
    let finished: () -> Void

    func makeUIView(context: Context) -> CinematicCrawlView { CinematicCrawlView() }
    func updateUIView(_ view: CinematicCrawlView, context: Context) {
        view.finished = finished
        view.setPaused(isPaused)
    }
    static func dismantleUIView(_ view: CinematicCrawlView, coordinator: ()) { view.cancel() }
}

@MainActor
private final class CinematicCrawlView: UIView {
    var finished: (() -> Void)?
    private let content = UIView()
    private let fade = CAGradientLayer()
    private var animator: UIViewPropertyAnimator?
    private var labels: [UILabel] = []
    private var lastSize = CGSize.zero
    private var paused = false
    private var completed = false
    private var needsRestart = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isAccessibilityElement = false
        addSubview(content)
        fade.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.16, 0.94, 1]
        layer.mask = fade
        for section in IntroScript.sections {
            let title = UILabel()
            title.numberOfLines = 0
            title.textAlignment = .center
            title.textColor = UIColor(red: 123 / 255, green: 200 / 255, blue: 1, alpha: 1)
            title.attributedText = NSAttributedString(string: section.title, attributes: [.kern: 1.8])
            let body = UILabel()
            body.numberOfLines = 0
            body.textAlignment = .center
            body.textColor = UIColor(red: 243 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 7
            body.attributedText = NSAttributedString(string: section.body, attributes: [.paragraphStyle: paragraph])
            labels.append(contentsOf: [title, body])
            content.addSubview(title)
            content.addSubview(body)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
        guard bounds.width > 0, bounds.height > 0, !completed else { return }
        guard lastSize != bounds.size || needsRestart else { return }
        let progress = animator?.fractionComplete ?? 0
        animator?.stopAnimation(true)
        lastSize = bounds.size
        needsRestart = false
        content.layer.transform = CATransform3DIdentity
        let width = min(bounds.width, 540)
        var y: CGFloat = 0
        for (index, label) in labels.enumerated() {
            let isTitle = index.isMultiple(of: 2)
            label.font = UIFontMetrics(forTextStyle: isTitle ? .headline : .title3).scaledFont(for:
                isTitle ? UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
                        : UIFont.systemFont(ofSize: 22, weight: .medium), compatibleWith: traitCollection)
            let height = ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            label.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height + (isTitle ? 18 : 52)
        }
        content.bounds = CGRect(x: 0, y: 0, width: width, height: y)
        let startY = bounds.height + y / 2
        let endY = -y / 2
        content.center = CGPoint(x: bounds.midX, y: startY)
        // A shallow tilt keeps the copy readable on a narrow phone screen.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 2400
        content.layer.transform = CATransform3DRotate(perspective, 10 * .pi / 180, 1, 0, 0)
        // Speed follows the readable viewport and line height, rather than a fixed
        // short deadline that would rush longer copy or larger text.
        let readableHeight = bounds.height * 0.78
        let speed = min(42, max(28, readableHeight / 13))
        let duration = Double((startY - endY) / speed)
        let motion = UIViewPropertyAnimator(duration: duration, curve: .linear) { [weak self] in
            guard let self else { return }
            self.content.center.y = endY
        }
        motion.addCompletion { [weak self] position in
            guard let self, position == .end, !self.completed else { return }
            self.completed = true
            self.finished?()
        }
        animator = motion
        motion.startAnimation()
        motion.pauseAnimation()
        motion.fractionComplete = progress
        if !paused { motion.startAnimation() }
    }

    func setPaused(_ value: Bool) {
        paused = value
        guard let animator, animator.state == .active else { return }
        if value { animator.pauseAnimation() }
        else if !animator.isRunning { animator.startAnimation() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            needsRestart = true
            setNeedsLayout()
        }
    }

    func cancel() {
        animator?.stopAnimation(true)
        animator = nil
        finished = nil
    }
}
