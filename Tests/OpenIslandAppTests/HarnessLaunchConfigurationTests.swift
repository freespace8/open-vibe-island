import Foundation
import Testing
@testable import OpenIslandApp

struct HarnessLaunchConfigurationTests {
    @Test
    func defaultsMatchNormalAppLaunch() {
        let configuration = HarnessLaunchConfiguration(environment: [:])

        #expect(configuration.scenario == nil)
        #expect(!configuration.presentOverlay)
        #expect(configuration.shouldShowControlCenter)
        #expect(configuration.shouldStartBridge)
        #expect(configuration.shouldPerformBootAnimation)
        #expect(configuration.autoExitAfter == nil)
    }

    @Test
    func parsesScenarioFlagsAndAutoExit() {
        let configuration = HarnessLaunchConfiguration(
            environment: [
                "OPEN_ISLAND_HARNESS_SCENARIO": "approvalcard",
                "OPEN_ISLAND_HARNESS_PRESENT_OVERLAY": "true",
                "OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER": "0",
                "OPEN_ISLAND_HARNESS_START_BRIDGE": "no",
                "OPEN_ISLAND_HARNESS_BOOT_ANIMATION": "off",
                "OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS": "2.5",
            ]
        )

        #expect(configuration.scenario == .approvalCard)
        #expect(configuration.presentOverlay)
        #expect(!configuration.shouldShowControlCenter)
        #expect(!configuration.shouldStartBridge)
        #expect(!configuration.shouldPerformBootAnimation)
        #expect(configuration.autoExitAfter == 2.5)
    }

    @Test
    func ignoresInvalidInputs() {
        let configuration = HarnessLaunchConfiguration(
            environment: [
                "OPEN_ISLAND_HARNESS_SCENARIO": "missing",
                "OPEN_ISLAND_HARNESS_PRESENT_OVERLAY": "unexpected",
                "OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS": "-1",
            ]
        )

        #expect(configuration.scenario == nil)
        #expect(!configuration.presentOverlay)
        #expect(configuration.autoExitAfter == nil)
    }
}
