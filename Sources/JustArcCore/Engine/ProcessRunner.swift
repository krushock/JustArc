import Foundation

/// Handed to callers so they can stop a long extraction.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    /// Registers work to do on cancellation, for waits that are not a subprocess.
    /// Fires immediately when cancellation already happened.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { process.terminate() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        let pending = handlers
        handlers.removeAll()
        lock.unlock()
        process?.terminate()
        for handler in pending { handler() }
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var combined: String {
        [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum ProcessRunner {
    /// Runs a tool to completion, streaming stdout so progress can be reported live.
    /// Output is decoded as UTF-8 with a lossy fallback, since archive listings can carry
    /// names in legacy encodings.
    public static func run(executable: URL,
                           arguments: [String],
                           currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           stdin: String? = nil,
                           cancellation: CancellationToken? = nil,
                           onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ArchiveError.engineMissing(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var env = environment ?? ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        let collector = OutputCollector(onOutput: onOutput)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.appendStandardOutput(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.appendStandardError(data)
        }

        cancellation?.attach(process)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever landed between the last handler call and exit.
                collector.appendStandardOutput(outPipe.fileHandleForReading.availableData)
                collector.appendStandardError(errPipe.fileHandleForReading.availableData)

                continuation.resume(returning: ProcessResult(
                    exitCode: finished.terminationStatus,
                    standardOutput: collector.standardOutputText,
                    standardError: collector.standardErrorText))
            }

            do {
                try process.run()
                if let inPipe, let stdin {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(throwing: ArchiveError.ioFailure(error.localizedDescription))
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private let onOutput: (@Sendable (String) -> Void)?

        init(onOutput: (@Sendable (String) -> Void)?) {
            self.onOutput = onOutput
        }

        func appendStandardOutput(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            outData.append(data)
            lock.unlock()
            if let onOutput, let chunk = String(data: data, encoding: .utf8) {
                onOutput(chunk)
            }
        }

        func appendStandardError(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            errData.append(data)
            lock.unlock()
        }

        var standardOutputText: String {
            lock.lock(); defer { lock.unlock() }
            return decode(outData)
        }

        var standardErrorText: String {
            lock.lock(); defer { lock.unlock() }
            return decode(errData)
        }

        private func decode(_ data: Data) -> String {
            String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        }
    }
}

extension ProcessRunner {
    /// Runs `first | second`. 7-Zip needs this for `.tar.gz` and friends, where the outer
    /// stream has to be decompressed before the tar inside it can be listed or extracted.
    public static func runPipeline(first: URL, firstArguments: [String],
                                   second: URL, secondArguments: [String],
                                   currentDirectory: URL? = nil,
                                   cancellation: CancellationToken? = nil,
                                   onOutput: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        for tool in [first, second] where !FileManager.default.isExecutableFile(atPath: tool.path) {
            throw ArchiveError.engineMissing(tool.path)
        }

        let upstream = Process()
        upstream.executableURL = first
        upstream.arguments = firstArguments

        let downstream = Process()
        downstream.executableURL = second
        downstream.arguments = secondArguments
        if let currentDirectory { downstream.currentDirectoryURL = currentDirectory }

        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        upstream.environment = env
        downstream.environment = env

        let bridge = Pipe()
        upstream.standardOutput = bridge
        downstream.standardInput = bridge

        let outPipe = Pipe()
        let errPipe = Pipe()
        let upstreamErrPipe = Pipe()
        downstream.standardOutput = outPipe
        downstream.standardError = errPipe
        upstream.standardError = upstreamErrPipe

        let collector = PipelineCollector(onOutput: onOutput)
        outPipe.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }
        upstreamErrPipe.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }

        cancellation?.attach(downstream)

        return try await withCheckedThrowingContinuation { continuation in
            downstream.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                upstreamErrPipe.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(outPipe.fileHandleForReading.availableData)
                collector.appendErr(errPipe.fileHandleForReading.availableData)
                if upstream.isRunning { upstream.terminate() }
                continuation.resume(returning: ProcessResult(exitCode: finished.terminationStatus,
                                                             standardOutput: collector.outText,
                                                             standardError: collector.errText))
            }
            do {
                try downstream.run()
                try upstream.run()
                // Closing our copy lets the reader see EOF once the writer exits.
                try? bridge.fileHandleForWriting.close()
            } catch {
                downstream.terminationHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                upstreamErrPipe.fileHandleForReading.readabilityHandler = nil
                if upstream.isRunning { upstream.terminate() }
                if downstream.isRunning { downstream.terminate() }
                continuation.resume(throwing: ArchiveError.ioFailure(error.localizedDescription))
            }
        }
    }

    private final class PipelineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private let onOutput: (@Sendable (String) -> Void)?

        init(onOutput: (@Sendable (String) -> Void)?) { self.onOutput = onOutput }

        func appendOut(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); out.append(data); lock.unlock()
            if let onOutput, let s = String(data: data, encoding: .utf8) { onOutput(s) }
        }

        func appendErr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); err.append(data); lock.unlock()
        }

        var outText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var errText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    }
}
