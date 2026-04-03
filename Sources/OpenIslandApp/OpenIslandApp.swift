import AppKit
import SwiftUI

@MainActor
final class OpenIslandAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Open Island should remain active while monitoring local agent sessions."
        )
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [self] in
            model.startIfNeeded()
            model.showControlCenter()
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
