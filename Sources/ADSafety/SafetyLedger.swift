import ADFoundation
import ADModel
import Foundation

public enum LedgerState: String, Codable, Sendable {
    case starting, active, ending, rescued
}

/// What a session changed, written before each risky step so that any process can undo it after a
/// crash. This file is the only way the guardian knows a session exists.
public struct SafetyLedger: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = SafetyLedger.currentSchemaVersion
    public var state: LedgerState
    public var client: String
    public var looksLike: ScreenSize
    public var hiDPI: Bool
    public var hz: Int
    public var keepOn: [String]
    public var physical: [PhysicalRecord]
    public var owners: [ProcessRef]
    public var app: ProcessRef?
    public var bootSessionID: String
    /// Identifies the session, so it must stay the same when a relaunched app takes it over.
    public var startedAt: Date
    public var updatedAt: Date
    /// Set by a restore child that verified the arrangement but found a recorded mode not offered. It
    /// leaves `rescued` unwritten, because a process that started while a monitor was off may never see
    /// that monitor's modes, and the next child is a fresh process. A child that finds this set and the
    /// mode missing again takes the mode to be gone. Optional, so a file without it still reads.
    public var restoreMissedModes: Bool?

    public init(
        state: LedgerState,
        client: String,
        looksLike: ScreenSize,
        hiDPI: Bool,
        hz: Int,
        keepOn: [String] = [],
        physical: [PhysicalRecord] = [],
        owners: [ProcessRef] = [],
        app: ProcessRef? = nil,
        bootSessionID: String,
        startedAt: Date,
        updatedAt: Date,
        restoreMissedModes: Bool? = nil
    ) {
        self.state = state
        self.client = client
        self.looksLike = looksLike
        self.hiDPI = hiDPI
        self.hz = hz
        self.keepOn = keepOn
        self.physical = physical
        self.owners = owners
        self.app = app
        self.bootSessionID = bootSessionID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.restoreMissedModes = restoreMissedModes
    }
}
