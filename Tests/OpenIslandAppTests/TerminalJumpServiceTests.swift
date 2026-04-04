import XCTest
@testable import OpenIslandApp
import OpenIslandCore
import Foundation

final class TerminalJumpServiceTests: XCTestCase {
    func testGhosttyJumpScriptActivatesWindowAndRetriesFocusUntilItSticks() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island",
            terminalSessionID: "448D7E28-24FB-46F1-9504-C252F97926C1"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("activate window targetWindow"))
        XCTAssertTrue(script.contains("select tab targetTab"))
        XCTAssertTrue(script.contains("focus targetTerminal"))
        XCTAssertTrue(script.contains("repeat 4 times"))
        XCTAssertTrue(script.contains("delay 0.12"))
        XCTAssertTrue(script.contains("focused terminal of selected tab of front window"))
        XCTAssertTrue(script.contains("repeat with aWindow in windows"))
        XCTAssertTrue(script.contains("repeat with aTab in tabs of aWindow"))
        XCTAssertTrue(script.contains("repeat with aTerminal in terminals of aTab"))
    }

    func testGhosttyJumpScriptFallsBackToWorkingDirectoryAndTitle() {
        let target = JumpTarget(
            terminalApp: "Ghostty",
            workspaceName: "open-island",
            paneTitle: "codex ~/p/open-island",
            workingDirectory: "/Users/wangruobing/Personal/open-island"
        )

        let script = TerminalJumpService().ghosttyJumpScript(for: target)

        XCTAssertTrue(script.contains("(working directory of aTerminal as text) is \"/Users/wangruobing/Personal/open-island\""))
        XCTAssertTrue(script.contains("(name of aTerminal as text) contains \"codex ~/p/open-island\""))
        XCTAssertTrue(script.contains("if \"\" is \"\" then"))
    }

    func testGhosttyJumpIntegrationMatchesFocusedTerminalForLiveSurfaces() throws {
        guard ProcessInfo.processInfo.environment["OPEN_ISLAND_RUN_GHOSTTY_JUMP_INTEGRATION"] == "1" else {
            throw XCTSkip("Set OPEN_ISLAND_RUN_GHOSTTY_JUMP_INTEGRATION=1 to run live Ghostty jump verification.")
        }

        let terminals = try liveGhosttyTerminals()
        if terminals.isEmpty {
            throw XCTSkip("No live Ghostty terminals were found.")
        }

        let service = TerminalJumpService()
        for terminal in terminals {
            let result = try service.jump(
                to: JumpTarget(
                    terminalApp: "Ghostty",
                    workspaceName: URL(fileURLWithPath: terminal.workingDirectory).lastPathComponent,
                    paneTitle: terminal.title,
                    workingDirectory: terminal.workingDirectory,
                    terminalSessionID: terminal.id
                )
            )

            XCTAssertEqual(result, "Focused the matching Ghostty terminal.")
            XCTAssertEqual(try focusedGhosttyTerminalID(), terminal.id)
        }
    }
}

private struct LiveGhosttyTerminal: Equatable {
    let id: String
    let workingDirectory: String
    let title: String
}

private let fieldSeparator = "\u{1f}"
private let recordSeparator = "\u{1e}"

private func liveGhosttyTerminals() throws -> [LiveGhosttyTerminal] {
    let script = """
    tell application "Ghostty"
        if not (it is running) then return ""
        set outputRecords to {}
        repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
                repeat with aTerminal in terminals of aTab
                    set end of outputRecords to (id of aTerminal as text) & "\(fieldSeparator)" & (working directory of aTerminal as text) & "\(fieldSeparator)" & (name of aTerminal as text)
                end repeat
            end repeat
        end repeat
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to "\(recordSeparator)"
        set joinedOutput to outputRecords as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedOutput
    end tell
    """

    let output = try runAppleScript(script)
    if output.isEmpty {
        return []
    }

    return output
        .components(separatedBy: recordSeparator)
        .compactMap { record in
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count == 3 else {
                return nil
            }

            return LiveGhosttyTerminal(id: fields[0], workingDirectory: fields[1], title: fields[2])
        }
}

private func focusedGhosttyTerminalID() throws -> String {
    let script = """
    tell application "Ghostty"
        if not (it is running) then return ""
        return id of focused terminal of selected tab of front window as text
    end tell
    """

    return try runAppleScript(script)
}

private func runAppleScript(_ script: String) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    try task.run()
    task.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard task.terminationStatus == 0 else {
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTFail(stderr.isEmpty ? "AppleScript command failed." : stderr)
        throw NSError(domain: "TerminalJumpServiceTests", code: Int(task.terminationStatus))
    }

    return output
}
