import ADModel

public struct SafetyRefusal: Error, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Any plan that disconnects a display must leave at least one display that counts.
public enum NeverZeroRule {
    private static let refusalReason = "would leave no working display"

    /// A sleeping physical display counts: it's online, and it wakes. Our own virtual screen counts
    /// only inside a session, because only a session has a ledger and a guardian to bring the
    /// monitors back if the screen goes away.
    public static func counts(_ display: DisplaySnapshot, inProtectedSession: Bool) -> Bool {
        guard display.isOnline else { return false }
        switch display.kind {
        case .physical: return true
        case .ownVirtual: return inProtectedSession
        case .parsecVirtual, .osFallback, .otherVirtual, .emptyPipe: return false
        }
    }

    public static func check(
        topology: Topology,
        disconnecting: Set<DisplayID>,
        inProtectedSession: Bool
    ) -> Result<Void, SafetyRefusal> {
        let oneRemains = topology.displays.contains {
            !disconnecting.contains($0.id) && counts($0, inProtectedSession: inProtectedSession)
        }
        return oneRemains ? .success(()) : .failure(SafetyRefusal(reason: refusalReason))
    }
}
