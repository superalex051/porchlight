import ADFoundation
import ADModel
import ADSPI
import ColorSync
import CoreGraphics
import Foundation

/// The real displays. Reads are always safe. `setEnabled` and `commit` crash in a test bundle unless
/// `AD_HIL=1`, and can block for about 10 seconds, so they never run on the main actor.
public final class LiveDisplayBackend: DisplayBackend {
    /// The spike's limit. The most IDs seen on this Mac so far is 6.
    private static let maxDisplays: UInt32 = 32
    private static let log = ADLog.logger("displays")

    public init() {
        // Some display calls abort until CoreGraphics has initialized, and this one initializes it.
        _ = CGMainDisplayID()
    }

    public func topology() -> Topology {
        let main = CGMainDisplayID()
        let online = Self.ids(from: CGGetOnlineDisplayList)
        let active = Self.ids(from: CGGetActiveDisplayList)

        // SkyLight adds disconnected displays and empty pipes to what the public list shows. Being
        // on a list is the only trustworthy answer: the per-ID online call lies during fallback.
        // Without this list, a monitor that's off looks like one that has been unplugged, so the
        // read has to say so. It's never empty on a working Mac, because the fallback display is on it.
        var ids = SkyLight.allDisplayIDs() ?? []
        let listReadFailed = ids.isEmpty
        if listReadFailed {
            Self.log.error("Reading the full display list failed")
        }
        ids += online.filter { !ids.contains($0) }

        let displays = ids.map { id in
            let info = CoreDisplayInfo.info(for: id)
            let identity = Self.identity(of: id, info: info)
            return DisplaySnapshot(
                id: id,
                identity: identity,
                kind: DisplayClassifier.kind(
                    isVirtual: CoreDisplayInfo.isVirtual(info),
                    vendor: identity.vendor,
                    model: identity.model,
                    name: identity.productName
                ),
                isOnline: online.contains(id),
                isActive: active.contains(id),
                isMain: id == main,
                // Not `!= 0`: an ID that has just gone away reads -1.
                isAsleep: CGDisplayIsAsleep(id) == 1,
                origin: Self.origin(of: id),
                mode: CGDisplayCopyDisplayMode(id).flatMap(Self.displayMode)
            )
        }
        return Topology(displays: DisplayClassifier.markingStaleTwins(displays), listReadFailed: listReadFailed)
    }

    public func modes(of id: DisplayID) -> [DisplayMode] {
        Self.cgModes(of: id).compactMap(Self.displayMode)
    }

    public func setEnabled(_ id: DisplayID, _ enabled: Bool) throws {
        try setEnabled([id], enabled)
    }

    /// One `CGBeginDisplayConfiguration`, one queued switch per ID in the order given, and one
    /// `CGCompleteDisplayConfiguration`. A switch that can't be queued cancels the lot.
    public func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws {
        guard !ids.isEmpty else { return }
        TestBundleGuard.preconditionMutationAllowed()
        for id in ids {
            try Self.requireDisplay(id)
        }
        let action = enabled ? "enable" : "disable"

        var opened: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&opened)
        guard begun == .success, let config = opened else { throw Self.failure(begun, "begin configuration") }

        for id in ids {
            let queued = DisplayEnable.configure(config, id, enabled: enabled)
            guard queued == .success else {
                CGCancelDisplayConfiguration(config)
                throw Self.failure(queued, "\(action) display \(id)")
            }
        }

        let completed = CGCompleteDisplayConfiguration(config, .forSession)
        guard completed == .success else {
            let named = ids.count == 1 ? "display \(ids[0])" : "displays \(ids.map(String.init).joined(separator: ", "))"
            throw Self.failure(completed, "\(action) \(named)")
        }
    }

    /// A mode the display doesn't list is left out, the rest is applied, and then the error names the
    /// display. This process's copy of a display can be stale, with no modes, after the monitor comes
    /// back, as the hardware run of 2026-11-07 found, and a stale list mustn't stop the origins.
    public func commit(_ changes: [DisplayChange]) throws {
        TestBundleGuard.preconditionMutationAllowed()
        let unlisted = changes.filter { change in
            // ID 0 stays in, so that `queue` refuses it as before.
            guard case .mode(let id, let mode) = change, id != 0 else { return false }
            return Self.cgMode(of: id, matching: mode) == nil
        }
        let applicable = changes.filter { !unlisted.contains($0) }
        if !applicable.isEmpty {
            try apply(applicable)
        }
        guard unlisted.isEmpty else {
            var ids: [DisplayID] = []
            var problems: [String] = []
            for case .mode(let id, let mode) in unlisted {
                ids.append(id)
                problems.append("display \(id) has no mode \(mode.pointsWide)x\(mode.pointsHigh) at \(mode.refreshHz) Hz")
            }
            throw DisplayBackendError(
                code: CGError.illegalArgument.rawValue,
                message: problems.joined(separator: "; "),
                modesNotApplied: ids
            )
        }
    }

    private func apply(_ changes: [DisplayChange]) throws {
        var opened: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&opened)
        guard begun == .success, let config = opened else { throw Self.failure(begun, "begin configuration") }

        do {
            for change in changes {
                try Self.queue(change, in: config)
            }
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }

        let completed = CGCompleteDisplayConfiguration(config, .forSession)
        guard completed == .success else { throw Self.failure(completed, "complete configuration") }
    }

    /// UUID lookup returns 0 for a monitor that's off, and ID 0 acts as the main display on reads, so
    /// a failed lookup must not reach a call that changes something. Throws 1001, as the simulator does.
    static func requireDisplay(_ id: DisplayID) throws {
        guard id != 0 else {
            throw DisplayBackendError(code: CGError.illegalArgument.rawValue, message: "display ID 0 is no display")
        }
    }

    private static func queue(_ change: DisplayChange, in config: CGDisplayConfigRef) throws {
        switch change {
        case .origin(let id, let origin):
            try requireDisplay(id)
            let result = CGConfigureDisplayOrigin(config, id, origin.x, origin.y)
            guard result == .success else { throw failure(result, "set the origin of display \(id)") }

        case .mode(let id, let mode):
            try requireDisplay(id)
            guard let match = cgMode(of: id, matching: mode) else {
                throw DisplayBackendError(
                    code: CGError.illegalArgument.rawValue,
                    message: "display \(id) has no mode \(mode.pointsWide)x\(mode.pointsHigh) at \(mode.refreshHz) Hz"
                )
            }
            let result = CGConfigureDisplayWithDisplayMode(config, id, match, nil)
            guard result == .success else { throw failure(result, "set the mode of display \(id)") }
        }
    }

    /// An exact match first, then one whose refresh rate rounds the same, so a recorded 120 finds a
    /// 119.88 Hz mode. The list includes low-resolution duplicates because a mode can be one of those.
    private static func cgMode(of id: DisplayID, matching wanted: DisplayMode) -> CGDisplayMode? {
        let modes = cgModes(of: id)
        return modes.first { displayMode($0) == wanted }
            ?? modes.first { displayMode($0)?.matches(wanted) == true }
    }

    private static func cgModes(of id: DisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// Nil for the 1x1 stub that disconnected displays and empty pipes read as. Measured in the spike,
    /// and recording one would make a restore try to set a 1x1 mode.
    private static func displayMode(_ mode: CGDisplayMode) -> DisplayMode? {
        guard mode.pixelWidth > 1 else { return nil }
        return DisplayMode(
            pointsWide: mode.width,
            pointsHigh: mode.height,
            pixelsWide: mode.pixelWidth,
            pixelsHigh: mode.pixelHeight,
            refreshHz: mode.refreshRate
        )
    }

    private static func identity(of id: DisplayID, info: [String: Any]) -> DisplayIdentity {
        DisplayIdentity(
            uuid: uuid(of: id),
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            // Key names from Apple's IOGraphicsTypes.h. Neither desk monitor has a serial string, and
            // empty pipes report a week and year of 0.
            alphanumericSerial: (info["DisplaySerialString"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            productName: CoreDisplayInfo.productName(info),
            registryLocation: CoreDisplayInfo.registryLocation(info),
            weekOfManufacture: (info["DisplayWeekManufacture"] as? Int).flatMap { $0 == 0 ? nil : $0 },
            yearOfManufacture: (info["DisplayYearManufacture"] as? Int).flatMap { $0 == 0 ? nil : $0 }
        )
    }

    private static func uuid(of id: DisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func origin(of id: DisplayID) -> DisplayOrigin {
        let origin = CGDisplayBounds(id).origin
        return DisplayOrigin(x: Int32(origin.x), y: Int32(origin.y))
    }

    private static func ids(
        from list: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [DisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let result = list(maxDisplays, &ids, &count)
        guard result == .success else {
            // An empty list reads as everything offline, so this mustn't pass unnoticed.
            log.error("Reading a display list failed with error \(result.rawValue)")
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    private static func failure(_ error: CGError, _ action: String) -> DisplayBackendError {
        DisplayBackendError(code: error.rawValue, message: "\(action) failed with error \(error.rawValue)")
    }
}
