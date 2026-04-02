import Foundation
import Testing
@testable import VibeIslandCore

struct ClaudeUsageTests {
    @Test
    func claudeUsageLoaderParsesCachedRateLimits() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-island-claude-usage-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("vibe-island-rl.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = """
        {
          "five_hour": {
            "used_percentage": 42,
            "resets_at": 1760000000
          },
          "seven_day": {
            "used_percentage": 17.5,
            "resets_at": 1760500000
          }
        }
        """
        try payload.write(to: cacheURL, atomically: true, encoding: .utf8)

        let snapshot = try ClaudeUsageLoader.load(from: cacheURL)

        #expect(snapshot?.fiveHour?.roundedUsedPercentage == 42)
        #expect(snapshot?.sevenDay?.roundedUsedPercentage == 18)
        #expect(snapshot?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(snapshot?.cachedAt != nil)
    }

    @Test
    func claudeStatusLineInstallationManagerInstallsManagedScriptWithoutOverwritingCustomCommand() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-island-claude-status-\(UUID().uuidString)", isDirectory: true)
        let claudeDirectory = rootURL.appendingPathComponent(".claude", isDirectory: true)
        let scriptDirectory = rootURL
            .appendingPathComponent(".vibe-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let manager = ClaudeStatusLineInstallationManager(
            claudeDirectory: claudeDirectory,
            scriptDirectoryURL: scriptDirectory
        )

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let installed = try manager.install()

        #expect(installed.managedStatusLineInstalled)
        #expect(installed.statusLineCommand == installed.scriptURL.path)
        #expect(FileManager.default.fileExists(atPath: installed.scriptURL.path))

        let settingsObject = try jsonObject(from: Data(contentsOf: installed.settingsURL))
        let statusLine = settingsObject["statusLine"] as? [String: Any]
        #expect(statusLine?["command"] as? String == installed.scriptURL.path)
        #expect(statusLine?["type"] as? String == "command")

        let scriptContents = try String(contentsOf: installed.scriptURL, encoding: .utf8)
        #expect(scriptContents.contains(installed.cacheURL.path))
        #expect(scriptContents.contains(".rate_limits // empty"))

        let uninstalled = try manager.uninstall()
        #expect(!uninstalled.managedStatusLineInstalled)
        #expect(!FileManager.default.fileExists(atPath: installed.scriptURL.path))
    }

    @Test
    func claudeStatusLineInstallationManagerRejectsExistingCustomStatusLine() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-island-claude-conflict-\(UUID().uuidString)", isDirectory: true)
        let claudeDirectory = rootURL.appendingPathComponent(".claude", isDirectory: true)
        let scriptDirectory = rootURL
            .appendingPathComponent(".vibe-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let manager = ClaudeStatusLineInstallationManager(
            claudeDirectory: claudeDirectory,
            scriptDirectoryURL: scriptDirectory
        )
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsData = try JSONSerialization.data(
            withJSONObject: [
                "theme": "dark",
                "statusLine": [
                    "type": "command",
                    "command": "/usr/local/bin/custom-status",
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try settingsData.write(to: settingsURL, options: .atomic)

        let status = try manager.status()
        #expect(status.hasConflictingStatusLine)
        #expect(status.statusLineCommand == "/usr/local/bin/custom-status")

        do {
            _ = try manager.install()
            Issue.record("Expected install to reject an existing custom status line")
        } catch let error as ClaudeStatusLineInstallationError {
            switch error {
            case let .existingStatusLineConflict(command):
                #expect(command == "/usr/local/bin/custom-status")
            default:
                Issue.record("Unexpected Claude status line error: \(error)")
            }
        }
    }
}

private func jsonObject(from data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}
