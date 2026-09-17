import Foundation
@testable import JustArcCore

/// Builds real archives on disk with the bundled 7zz so tests exercise the actual engine.
enum FixtureBuilder {
    static var sevenZip: URL {
        get throws { try EngineLocator.requireSevenZip() }
    }

    static func makeSourceTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("justarc-tests-\(UUID().uuidString)")
        let docs = root.appendingPathComponent("payload/docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        try "hello world\n".write(to: root.appendingPathComponent("payload/readme.txt"),
                                 atomically: true, encoding: .utf8)
        try String(repeating: "compress me ", count: 500)
            .write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "unicode: привет Ünïcode 日本語\n"
            .write(to: docs.appendingPathComponent("ünïcode.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(executable: try sevenZip,
                                                 arguments: arguments + ["-y"],
                                                 currentDirectory: directory)
        return result
    }

    /// Returns (sourceRoot, archiveURL). Caller removes sourceRoot.
    static func makeArchive(named name: String, extraArguments: [String] = []) async throws -> (URL, URL) {
        let root = try makeSourceTree()
        let archive = root.appendingPathComponent(name)
        let result = try await run(["a", archive.path] + extraArguments + ["payload"], in: root)
        guard result.exitCode == 0 else {
            throw ArchiveError.engineFailed(code: result.exitCode, message: result.combined)
        }
        return (root, archive)
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
