import AppKit
import Testing
@testable import OpenIslandApp

@MainActor
struct OpenIslandAppDelegateTests {
    @Test
    func hidesRegularWindowsOnLaunch() {
        let window = NSWindow()

        #expect(OpenIslandAppDelegate.shouldHideOnLaunch(window))
    }

    @Test
    func keepsOverlayPanelVisibleOnLaunch() {
        let window = NSPanel()
        window.identifier = OpenIslandWindowIdentifier.overlayPanel

        #expect(!OpenIslandAppDelegate.shouldHideOnLaunch(window))
    }

    @Test
    func keepsMenuBarExtraVisibleOnLaunch() {
        let window = FakeMenuBarExtraWindow()

        #expect(!OpenIslandAppDelegate.shouldHideOnLaunch(window))
    }
}

private final class FakeMenuBarExtraWindow: NSWindow {}
