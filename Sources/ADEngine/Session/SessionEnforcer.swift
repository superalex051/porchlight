import ADDisplayConfig
import ADModel
import ADSafety
import ADVirtualScreens
import Foundation

/// A recorded monitor found online while the session means it to be off.
struct ReturnedDisplay {
    var record: PhysicalRecord
    var display: DisplaySnapshot
}

/// The spec's limits on keeping a session in shape, and the reads that decide what's out of shape.
/// It changes no display: `SessionController` acts on what this says.
struct SessionEnforcer {
    /// What enforcement can keep doing, each with a budget of its own. A monitor goes by its recorded
    /// ID, which stays the same if it comes back under another.
    enum Target: Hashable {
        case monitor(DisplayID)
        case main
        case screen
    }

    static let debounceSeconds = 1.0
    static let startupPollSeconds = 15.0
    static let actionsPerWindow = 5
    static let windowSeconds = 60.0

    private var recent: [Target: [Date]] = [:]
    private var pollEndsAt: Date?

    /// Starts over for a session that has just become active in this process.
    mutating func sessionBecameActive(at now: Date) {
        recent = [:]
        pollEndsAt = now.addingTimeInterval(Self.startupPollSeconds)
    }

    mutating func sessionEnded() {
        recent = [:]
        pollEndsAt = nil
    }

    func isPolling(at now: Date) -> Bool {
        pollEndsAt.map { now <= $0 } ?? false
    }

    /// Counts an action on each of these and returns true, or returns false and counts nothing if any
    /// of them has used up its budget.
    mutating func spend(_ targets: [Target], at now: Date) -> Bool {
        for target in targets {
            recent[target, default: []].removeAll { now.timeIntervalSince($0) >= Self.windowSeconds }
        }
        guard targets.allSatisfy({ recent[$0, default: []].count < Self.actionsPerWindow }) else {
            return false
        }
        for target in targets {
            recent[target, default: []].append(now)
        }
        return true
    }

    /// What's online that the session recorded, in the order to turn it off: the old main last. A
    /// display `-keepon` named is never among them, even if a recorded one could pass for it.
    static func returned(_ ledger: SafetyLedger, in topology: Topology) -> [ReturnedDisplay] {
        let kept = Set(ledger.keepOn.map { $0.uppercased() })
        return disconnectOrder(ledger.physical).compactMap { record in
            guard let display = record.onlineDisplay(in: topology),
                display.identity.uuid.map({ !kept.contains($0.uppercased()) }) ?? true
            else { return nil }
            return ReturnedDisplay(record: record, display: display)
        }
    }

    static func disconnectOrder(_ records: [PhysicalRecord]) -> [PhysicalRecord] {
        records.filter { !$0.wasMain } + records.filter(\.wasMain)
    }

    /// A display that has just gone away can read online once, as an empty pipe.
    static func isOnline(_ screen: ActiveVirtualScreen, in topology: Topology) -> Bool {
        topology.online.contains { $0.id == screen.displayID && $0.kind != .emptyPipe }
    }

    /// Whether the restored monitors still read as the restorer left them, now that the screen has
    /// gone. With the old main missing, macOS picks a new main and shifts everything to keep it at
    /// (0,0), so only the positions relative to each other can match. With the old main back, or kept
    /// on so that it was never recorded, they have to match exactly.
    static func arrangementHolds(
        _ records: [PhysicalRecord],
        missing: [PhysicalRecord],
        modeNotOffered: [PhysicalRecord],
        in topology: Topology
    ) -> Bool {
        guard !topology.listReadFailed else { return false }

        let present = records.compactMap { record in
            record.onlineDisplay(in: topology).map { ReturnedDisplay(record: record, display: $0) }
        }
        let absent = records.filter { record in !present.contains { $0.record == record } }
        guard absent.allSatisfy(missing.contains) else { return false }
        guard let first = present.first else { return true }

        let oldMainIsMissing = absent.contains(where: \.wasMain)
        let shiftX = oldMainIsMissing ? first.display.origin.x - first.record.origin.x : 0
        let shiftY = oldMainIsMissing ? first.display.origin.y - first.record.origin.y : 0
        return present.allSatisfy { item in
            let origin = item.record.origin
            return item.display.origin == DisplayOrigin(x: origin.x + shiftX, y: origin.y + shiftY)
                && (modeNotOffered.contains(item.record) || item.display.mode?.matches(item.record.mode) == true)
        }
    }
}

// `PhysicalRecord.onlineDisplay(in:)` comes from ADDisplayConfig, so enforcement finds a monitor by
// the same rule as the restorer.
extension PhysicalRecord {
    /// For a warning. Identity was recorded with the display online, so the name is normally there.
    var displayName: String {
        identity.productName ?? "display \(id)"
    }
}
