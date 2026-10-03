import SwiftUI

/// The first-run tour and the replay from Chat's Info sheet share one experience.
struct OnboardingView: View {
    let finish: () -> Void
    let isReplay: Bool

    @State private var page: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedPage: String?

    private var secondaryInk: Color {
        AppearanceStore.shared.colorWay == .dark
            ? AppPalette.silver : Color(red: 0.35, green: 0.35, blue: 0.38)
    }

    init(initialPage: Int = 0, isReplay: Bool = false, finish: @escaping () -> Void) {
        self.finish = finish
        self.isReplay = isReplay
        _page = State(initialValue: min(max(initialPage, 0), OnboardingCopy.pageCount - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $page) {
                ForEach(Array(OnboardingCopy.pages.enumerated()), id: \.element.id) { index, item in
                    tourPage(item).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            controls
        }
        .background(AppPalette.background.ignoresSafeArea())
        .foregroundStyle(AppPalette.foreground)
        .lilCPreferredScheme(AppearanceStore.shared.colorWay)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
        .onChange(of: page) { _, newPage in
            focusedPage = OnboardingCopy.pages[newPage].id
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { move(to: page - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page == 0)
            .opacity(page == 0 ? 0 : 1)
            .accessibilityHidden(page == 0)
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("onboarding.back")
            Spacer(minLength: 0)
            Text("Edsger")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(isReplay ? "Done" : OnboardingCopy.skipTitle, action: finish)
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.skip")
        }
        .foregroundStyle(AppPalette.foreground)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func tourPage(_ item: OnboardingCopy.Page) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer(minLength: 0)
                    artwork(item, compact: geometry.size.height < 640)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.headline)
                            .font(.title.weight(.semibold))
                            .tracking(-0.7)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("onboarding.headline." + item.id)
                            .accessibilityFocused($focusedPage, equals: item.id)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(item.features) { feature in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: feature.symbol)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(AppPalette.green)
                                    .frame(width: 24, height: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title).font(.subheadline.weight(.semibold))
                                    Text(feature.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(secondaryInk)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text(item.footnote)
                        .font(.caption)
                        .foregroundStyle(secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func artwork(_ item: OnboardingCopy.Page, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.label)
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(secondaryInk)
            ViewThatFits(in: .horizontal) {
                ascii(item.artwork, size: compact ? 14 : 18)
                ascii(item.artwork, size: 14)
                ascii(item.artwork, size: 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(AppPalette.line, lineWidth: 1))
        // Art repeats the text's meaning; reading punctuation aloud adds noise.
        .accessibilityHidden(true)
    }

    private func ascii(_ text: String, size: CGFloat) -> some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(AppPalette.green)
            .fixedSize()
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach(0..<OnboardingCopy.pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? AppPalette.green : AppPalette.line)
                        .frame(width: index == page ? 22 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(OnboardingCopy.pageCount)")
            .accessibilityValue(OnboardingCopy.pages[page].headline.replacingOccurrences(of: "\n", with: " "))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(to: page + 1)
                case .decrement: move(to: page - 1)
                @unknown default: break
                }
            }

            Button(action: advance) {
                Text(page == OnboardingCopy.pageCount - 1
                     ? (isReplay ? "Done" : OnboardingCopy.getStartedTitle)
                     : OnboardingCopy.continueTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppPalette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .padding(.vertical, 4)
                    .background(AppPalette.green, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding.primary")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(AppPalette.background)
    }

    private func move(to index: Int) {
        let target = min(max(index, 0), OnboardingCopy.pageCount - 1)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            page = target
        }
    }

    private func advance() {
        if page == OnboardingCopy.pageCount - 1 {
            finish()
        } else {
            move(to: page + 1)
        }
    }
}
