import Foundation
import Testing
@testable import OpenIslandCore

struct PiSessionDiscoveryTests {
    @Test
    func discoversRecentPiSessionFromJsonlTranscript() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-pi-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = rootURL
            .appendingPathComponent("--Users-test-project--", isDirectory: true)
        let sessionURL = sessionDirectory
            .appendingPathComponent("2026-04-13T04-29-05-418Z_8ca34778-2f5a-4b0f-b075-f80a801a44d8.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try """
        {"type":"session","version":3,"id":"8ca34778-2f5a-4b0f-b075-f80a801a44d8","timestamp":"2026-04-13T04:29:05.418Z","cwd":"/tmp/project"}
        {"type":"message","id":"1","timestamp":"2026-04-13T04:29:06.000Z","message":{"role":"user","content":[{"type":"text","text":"检查当前 git 状态"}]}}
        {"type":"message","id":"2","timestamp":"2026-04-13T04:29:07.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_1","name":"bash","arguments":{"command":"git status -sb"}},{"type":"text","text":"我先看下当前仓库状态。"}]}}
        {"type":"message","id":"3","timestamp":"2026-04-13T04:29:08.000Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"## main"}],"isError":false}}
        {"type":"message","id":"4","timestamp":"2026-04-13T04:29:09.000Z","message":{"role":"assistant","content":[{"type":"text","text":"当前工作区是干净的。"}]}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let discovery = PiSessionDiscovery(rootURL: rootURL)
        let sessions = discovery.discoverRecentSessions(now: ISO8601DateFormatter().date(from: "2026-04-13T05:00:00Z")!)

        #expect(sessions.count == 1)
        #expect(sessions[0].tool == .piAgent)
        #expect(sessions[0].id == "8ca34778-2f5a-4b0f-b075-f80a801a44d8")
        #expect(sessions[0].title == "Pi · project")
        #expect(sessions[0].jumpTarget?.workingDirectory == "/tmp/project")
        #expect(
            URL(fileURLWithPath: sessions[0].piMetadata?.transcriptPath ?? "").resolvingSymlinksInPath().path
                == sessionURL.resolvingSymlinksInPath().path
        )
        #expect(sessions[0].piMetadata?.initialUserPrompt == "检查当前 git 状态")
        #expect(sessions[0].piMetadata?.lastAssistantMessage == "当前工作区是干净的。")
        #expect(sessions[0].summary == "当前工作区是干净的。")
    }
}
