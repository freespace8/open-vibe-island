import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

struct ActiveAgentProcessDiscoveryPiTests {
    @Test
    func discoverPiSessionFromOpenSessionFile() {
        let discovery = ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" {
                return """
                  103 301 ttys003 pi
                  301 900 ttys003 -/opt/homebrew/bin/fish
                  900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
                """
            }

            guard executablePath == "/usr/sbin/lsof",
                  let pid = arguments.dropFirst(2).first else {
                return nil
            }

            switch pid {
            case "103":
                return """
                fcwd
                n/tmp/open-island
                n/Users/test/.pi/agent/sessions/--tmp-open-island--/2026-04-13T04-29-05-418Z_8ca34778-2f5a-4b0f-b075-f80a801a44d8.jsonl
                """
            default:
                Issue.record("unexpected lsof lookup for pid \(pid)")
                return nil
            }
        }

        let snapshots = discovery.discover()

        #expect(snapshots == [
            .init(
                tool: .piAgent,
                sessionID: "8ca34778-2f5a-4b0f-b075-f80a801a44d8",
                workingDirectory: "/tmp/open-island",
                terminalTTY: "/dev/ttys003",
                terminalApp: "Ghostty",
                transcriptPath: "/Users/test/.pi/agent/sessions/--tmp-open-island--/2026-04-13T04-29-05-418Z_8ca34778-2f5a-4b0f-b075-f80a801a44d8.jsonl",
                processPID: 103
            ),
        ])
    }
}
