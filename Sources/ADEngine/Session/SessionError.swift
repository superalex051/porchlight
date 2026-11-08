import ADDisplayConfig
import ADDisplays
import ADSafety
import ADVirtualScreens

/// Why a session call failed. `reason` is what the CLI prints after `Failed.`.
nonisolated public struct SessionError: Error, Equatable, CustomStringConvertible {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }

    static let guardianNotRunning = SessionError(reason: "guardian not running")
    static let cannotWriteState = SessionError(reason: "cannot write state")
    static let noSession = SessionError(reason: "no session")
    static let couldNotRestore = SessionError(reason: "could not restore any display")
    static let didNotComeBack = SessionError(reason: "a display did not come back correctly")
    static let noPhysicalDisplay = SessionError(reason: "no physical display to return to")
    static let noDisplaysFound = SessionError(reason: "no displays found")
    static let appIsQuitting = SessionError(reason: "app is quitting")
    static let lastEndUnfinished = SessionError(reason: "the last session did not end cleanly; run porchlight rescue")

    static func heldBy(_ client: String) -> SessionError {
        SessionError(reason: "session held by \(client)")
    }

    static func ownerNotRunning(_ pid: Int32) -> SessionError {
        SessionError(reason: "owner process \(pid) is not running")
    }

    static func cannotRead(_ display: String) -> SessionError {
        SessionError(reason: "cannot read display \(display)")
    }
}

/// How an end went, when it succeeded.
nonisolated public struct EndOutcome: Sendable, Equatable {
    /// The names of recorded displays that have gone, as an unplugged monitor has.
    public var missing: [String]
    /// The names of displays that came back but no longer offer their recorded mode.
    public var notAtRecordedMode: [String]

    public init(missing: [String] = [], notAtRecordedMode: [String] = []) {
        self.missing = missing
        self.notAtRecordedMode = notAtRecordedMode
    }

    /// What the CLI prints after `warning:`, or nil if all went as recorded.
    public var warning: String? {
        let lines = missing.map { "not restored: \($0)" }
            + notAtRecordedMode.map { "not restored at recorded mode: \($0)" }
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }
}

extension Error {
    /// The words for this error in a session's failure reason and its log.
    nonisolated var sessionReason: String {
        switch self {
        case let error as SessionError: error.reason
        case let error as VirtualScreenError: error.reason
        case let error as DisplayOperationError: error.description
        case let error as DisplayBackendError: error.message
        case let error as SafetyRefusal: error.reason
        default: String(describing: self)
        }
    }
}
