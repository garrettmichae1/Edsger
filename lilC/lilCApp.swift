import SwiftUI
import UIKit

@main
struct lilCApp: App {
    @State private var appearance = AppearanceStore.shared
    @State private var onboarding = OnboardingStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarding.needsOnboarding {
                    OnboardingView { onboarding.complete() }
                } else {
                    ContentView()
                }
            }
            .lilCPreferredScheme(appearance.colorWay)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: onboarding.hasCompleted)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                LocalAgentClient.shared.handleMemoryPressure()
            }
            .task {
                await AgentSettingsStore.shared.loadStore()
                await MobileAgentStore.shared.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await AgentSettingsStore.shared.refreshEntitlements()
                        await MobileAgentStore.shared.refresh()
                    }
                }
            }
            .onAppear {
                _ = SoftwareKeyboard.shared
                AppHaptics.prepare()
            }
        }
    }
}
