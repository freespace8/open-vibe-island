import Foundation
import Testing
@testable import OpenIslandCore

struct PiHooksTests {
    @Test
    func piHookPayloadDecodesFromJSON() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "pi-123",
          "cwd": "/Users/test/project",
          "transcript_path": "/Users/test/.pi/agent/sessions/pi-123.jsonl",
          "tool_name": "bash",
          "tool_input": "{\\"command\\":\\"ls -la\\"}",
          "prompt": "Inspect the repo"
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(PiHookPayload.self, from: json)
        #expect(payload.hookEventName == .preToolUse)
        #expect(payload.sessionID == "pi-123")
        #expect(payload.cwd == "/Users/test/project")
        #expect(payload.transcriptPath?.hasSuffix("pi-123.jsonl") == true)
        #expect(payload.toolName == "bash")
        #expect(payload.prompt == "Inspect the repo")
    }

    @Test
    func piHookPayloadConvenienceProperties() {
        let payload = PiHookPayload(
            hookEventName: .preToolUse,
            sessionID: "pi-123",
            cwd: "/Users/test/project",
            transcriptPath: "/Users/test/.pi/agent/sessions/pi-123.jsonl",
            toolName: "bash",
            toolInput: "{\"command\":\"ls -la\"}",
            prompt: "Inspect the repo"
        )

        #expect(payload.workspaceName == "project")
        #expect(payload.sessionTitle == "Pi · project")
        #expect(payload.defaultJumpTarget.workingDirectory == "/Users/test/project")
        #expect(payload.defaultPiMetadata.currentTool == "bash")
        #expect(payload.defaultPiMetadata.transcriptPath?.hasSuffix("pi-123.jsonl") == true)
    }

    @Test
    func bridgeCommandRoundTripsPiHook() throws {
        let payload = PiHookPayload(
            hookEventName: .sessionStart,
            sessionID: "pi-123",
            cwd: "/tmp/workspace"
        )
        let command = BridgeCommand.processPiHook(payload)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(BridgeCommand.self, from: data)
        #expect(decoded == command)
    }

    @Test
    func piExtensionInstallationManagerRoundTripsInstallAndUninstall() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-pi-extension-\(UUID().uuidString)", isDirectory: true)
        let manager = PiExtensionInstallationManager(piAgentDirectory: rootURL)

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let installStatus = try manager.install(extensionSourceData: Data("export default {}".utf8))
        #expect(installStatus.isInstalled == true)
        #expect(FileManager.default.fileExists(atPath: installStatus.extensionFileURL.path))
        #expect(FileManager.default.fileExists(atPath: installStatus.manifestURL.path))

        let uninstallStatus = try manager.uninstall()
        #expect(uninstallStatus.isInstalled == false)
        #expect(!FileManager.default.fileExists(atPath: installStatus.extensionFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: installStatus.manifestURL.path))
    }
}
