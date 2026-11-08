import Darwin
import Foundation
import Synchronization

/// Runs a program and waits for it, but never past a limit, because a hung helper must not stop the
/// process waiting on it. The wait blocks the calling thread.
public enum BoundedProcess {
    public enum Outcome: Sendable, Equatable {
        case succeeded
        case failed
        case timedOut
    }

    public enum AtLimit: Sendable, Equatable {
        /// A slow program may still do its job.
        case leaveRunning
        /// SIGTERM, then SIGKILL if it's still there this many seconds later.
        case stop(killGrace: Double)
    }

    public struct Completion: Sendable, Equatable {
        public var outcome: Outcome
        /// The exit status, or nil if a signal ended the program or it ran past the limit.
        public var status: Int32?
        /// What it wrote to stdout.
        public var output: String

        /// `output`'s lines, without blank ones.
        public var outputLines: [String] {
            output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.allSatisfy(\.isWhitespace) }
        }
    }

    /// Throws only if the program couldn't start. Its input is always empty. Its output goes nowhere
    /// unless `inheritOutput` is true.
    public static func run(
        path: String,
        arguments: [String],
        limit: Double,
        atLimit: AtLimit,
        inheritOutput: Bool = false
    ) throws -> Outcome {
        let discarded: FileHandle? = inheritOutput ? nil : FileHandle.nullDevice
        return try execute(path, arguments, limit, atLimit, standardOutput: discarded, standardError: discarded).outcome
    }

    /// The same, but stdout is read, and stderr goes nowhere unless `inheritStandardError` is true.
    public static func runCapturingOutput(
        path: String,
        arguments: [String],
        limit: Double,
        atLimit: AtLimit,
        inheritStandardError: Bool = false
    ) throws -> Completion {
        let pipe = Pipe()
        let reader = OutputReader(pipe.fileHandleForReading)
        var completion = try execute(
            path,
            arguments,
            limit,
            atLimit,
            standardOutput: pipe,
            standardError: inheritStandardError ? nil : FileHandle.nullDevice
        )
        completion.output = reader.collected()
        return completion
    }

    /// Nil for a stream means the program shares this process's.
    private static func execute(
        _ path: String,
        _ arguments: [String],
        _ limit: Double,
        _ atLimit: AtLimit,
        standardOutput: Any?,
        standardError: Any?
    ) throws -> Completion {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let standardOutput { process.standardOutput = standardOutput }
        if let standardError { process.standardError = standardError }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        guard exited.wait(timeout: .now() + limit) == .success else {
            if case .stop(let killGrace) = atLimit {
                process.terminate()
                if exited.wait(timeout: .now() + killGrace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            return Completion(outcome: .timedOut, status: nil, output: "")
        }
        let status = process.terminationReason == .exit ? process.terminationStatus : nil
        return Completion(outcome: status == 0 ? .succeeded : .failed, status: status, output: "")
    }
}

/// Reads a pipe to its end on its own queue from the start, so a program that writes more than the pipe
/// holds can't stall waiting for a reader.
private final class OutputReader: Sendable {
    /// After the program has gone, for anything it left running that still holds the pipe open.
    private static let lingerLimit = 1.0

    private let data = Mutex(Data())
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue(label: "com.alexluncan.PorchLight.process-output", qos: .userInitiated).async { [self] in
            let read = handle.readDataToEndOfFile()
            data.withLock { $0 = read }
            finished.signal()
        }
    }

    func collected() -> String {
        _ = finished.wait(timeout: .now() + Self.lingerLimit)
        return String(decoding: data.withLock { $0 }, as: UTF8.self)
    }
}
