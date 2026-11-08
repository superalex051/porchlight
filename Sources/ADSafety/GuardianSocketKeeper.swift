import ADFoundation
import Foundation

/// Gets `guardian.sock` listening, and keeps trying if it can't. The socket only serves session
/// start's check for a live guardian, and a refused new session is the safe direction. A live session
/// depends on the watching loop instead, so a socket that won't open, on a full disk or with a stray
/// file at its path, must not stop that loop. Only another live guardian is a reason to exit, because
/// two would both act on the same ledger.
public struct GuardianSocketKeeper: Sendable {
    public enum Outcome: Sendable, Equatable {
        case listening
        case anotherGuardianIsListening
        case failed
    }

    /// The same spacing launchd gives a guardian that exits.
    public static let retryInterval: Double = 5

    private let start: @Sendable () throws -> Void
    private let anotherGuardianAnswers: @Sendable () async -> Bool
    private let clock: any ADClock
    private let log: @Sendable (String) -> Void
    private let exitProcess: @Sendable () -> Void

    /// `anotherGuardianAnswers` runs only after `start` throws, and tells a live guardian from a
    /// socket that's merely in the way.
    public init(
        start: @escaping @Sendable () throws -> Void,
        anotherGuardianAnswers: @escaping @Sendable () async -> Bool,
        clock: any ADClock,
        log: @escaping @Sendable (String) -> Void,
        exit: @escaping @Sendable () -> Void
    ) {
        self.start = start
        self.anotherGuardianAnswers = anotherGuardianAnswers
        self.clock = clock
        self.log = log
        self.exitProcess = exit
    }

    /// One try. If another guardian answers, this ends the process through `exit`.
    @concurrent public func attempt() async -> Outcome {
        do {
            try start()
            return .listening
        } catch {
            guard await anotherGuardianAnswers() else {
                let every = Int(Self.retryInterval)
                log("cannot open the guardian socket, watching without it and retrying every \(every) s: \(error)")
                return .failed
            }
            log("another guardian is listening, exiting")
            exitProcess()
            return .anotherGuardianIsListening
        }
    }

    /// For after a failed `attempt`. Returns once the socket is up, another guardian holds it or the
    /// task is cancelled.
    @concurrent public func keepTrying() async {
        while true {
            do {
                try await clock.sleep(seconds: Self.retryInterval)
            } catch {
                return
            }
            switch await attempt() {
            case .listening:
                log("the guardian socket is up")
                return
            case .anotherGuardianIsListening:
                return
            case .failed:
                continue
            }
        }
    }
}
