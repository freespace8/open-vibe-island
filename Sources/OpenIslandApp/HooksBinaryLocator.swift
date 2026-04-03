import Foundation

enum HooksBinaryLocator {
    static func locate() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let explicitPath = environment["OPEN_ISLAND_HOOKS_BINARY"] ?? environment["VIBE_ISLAND_HOOKS_BINARY"],
           fileManager.isExecutableFile(atPath: explicitPath) {
            return URL(fileURLWithPath: explicitPath).standardizedFileURL
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()

        let candidates = [
            executableDirectory?.appendingPathComponent("OpenIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("OpenIslandHooks"),
            executableDirectory?.appendingPathComponent("VibeIslandHooks"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("VibeIslandHooks"),
            currentDirectory.appendingPathComponent(".build/debug/OpenIslandHooks"),
            currentDirectory.appendingPathComponent(".build/release/OpenIslandHooks"),
            currentDirectory.appendingPathComponent(".build/arm64-apple-macosx/debug/OpenIslandHooks"),
            currentDirectory.appendingPathComponent(".build/arm64-apple-macosx/release/OpenIslandHooks"),
            currentDirectory.appendingPathComponent(".build/debug/VibeIslandHooks"),
            currentDirectory.appendingPathComponent(".build/release/VibeIslandHooks"),
            currentDirectory.appendingPathComponent(".build/arm64-apple-macosx/debug/VibeIslandHooks"),
            currentDirectory.appendingPathComponent(".build/arm64-apple-macosx/release/VibeIslandHooks"),
        ]

        for candidate in candidates.compactMap({ $0 }) where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }

        return nil
    }
}
