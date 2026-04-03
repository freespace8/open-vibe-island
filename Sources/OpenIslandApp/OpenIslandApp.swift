import AppKit
import SwiftUI

@MainActor
final class OpenIslandAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let harnessLaunchConfiguration = HarnessLaunchConfiguration()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Open Island should remain active while monitoring local agent sessions."
        )
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [self] in
            model.startIfNeeded(
                startBridge: harnessLaunchConfiguration.shouldStartBridge,
                shouldPerformBootAnimation: harnessLaunchConfiguration.shouldPerformBootAnimation
            )

            if let scenario = harnessLaunchConfiguration.scenario {
                model.loadDebugSnapshot(
                    scenario.snapshot(),
                    presentOverlay: harnessLaunchConfiguration.presentOverlay
                )
            }

            if harnessLaunchConfiguration.shouldShowControlCenter {
                model.showControlCenter()
            }

            if let autoExitAfter = harnessLaunchConfiguration.autoExitAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + autoExitAfter) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showControlCenter()
        return false
    }
}

@main
struct OpenIslandApp: App {
    @NSApplicationDelegateAdaptor(OpenIslandAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup("Open Island Debug") {
            ControlCenterView(model: appDelegate.model)
        }

        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model)
        } label: {
            OpenIslandBrandMark(size: 18, style: .template)
                .accessibilityLabel("Open Island")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
