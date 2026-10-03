import SwiftUI

/// A single, scrollable introduction shared by first launch and replay.
struct OnboardingView: View {
    let isReplay: Bool
    let finish: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var background: Color { scheme == .dark ? Color(white: 0.055) : .white }
    private var secondaryInk: Color { scheme == .dark ? Color(white: 0.7) : Color(white: 0.35) }

    init(isReplay: Bool = false, finish: @escaping () -> Void) {
        self.isReplay = isReplay
        self.finish = finish
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Edsger")
                    .font(.headline)
                    .foregroundStyle(secondaryInk)
                VStack(alignment: .leading, spacing: 18) {
                    Text(OnboardingCopy.headline)
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.headline")
                    Text(OnboardingCopy.introduction)
                        .font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                section(OnboardingCopy.localTitle, body: OnboardingCopy.localBody)
                section(OnboardingCopy.featuresTitle, body: OnboardingCopy.featuresBody)
                Divider()
                section(OnboardingCopy.commitmentTitle, body: OnboardingCopy.commitmentBody)
                    .accessibilityIdentifier("onboarding.commitment")
                Text(OnboardingCopy.footnote)
                    .font(.footnote)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("onboarding.scroll")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: finish) {
                Text(isReplay ? "Done" : OnboardingCopy.getStartedTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .padding(.vertical, 4)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding.primary")
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(background)
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(Color.primary)
        .lilCPreferredScheme(AppearanceStore.shared.colorWay)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
    }

    private func section(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.body)
                .foregroundStyle(secondaryInk)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
