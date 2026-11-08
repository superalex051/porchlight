import ADDisplays
import ADFoundation
import ADModel
import Foundation

public enum DisplayOperationError: Error, Equatable, CustomStringConvertible {
    case notOnline(DisplayID)
    case stillOnline(DisplayID)
    case didNotReturn(DisplayID)
    case notMain(DisplayID)
    /// The text says what was asked for.
    case noSuchMode(DisplayID, String)
    case modeNotApplied(DisplayID, String)

    public var description: String {
        switch self {
        case .notOnline(let id): "display \(id) is not online"
        case .stillOnline(let id): "display \(id) is still online 3 seconds after turning it off"
        case .didNotReturn(let id): "display \(id) did not come online after turning it on"
        case .notMain(let id): "display \(id) did not become the main display"
        case .noSuchMode(let id, let wanted): "display \(id) has no mode \(wanted)"
        case .modeNotApplied(let id, let wanted): "display \(id) did not switch to \(wanted)"
        }
    }
}

/// One change to the displays, verified afterward. A live call can block for about 10 seconds, so
/// every method here runs off the caller's actor.
public struct DisplayOperations: Sendable {
    private static let pollSeconds = 0.1
    private static let disconnectLimitSeconds = 3.0
    /// How long the restorer gives a monitor to come back.
    private static let connectLimitSeconds = 15.0
    private static let verifyLimitSeconds = 3.0
    /// How long the restorer lets an arrangement settle before reading it back.
    private static let settleSeconds = 0.8

    private let backend: any DisplayBackend
    private let clock: any ADClock

    public init(backend: any DisplayBackend, clock: any ADClock) {
        self.backend = backend
        self.clock = clock
    }

    /// Main is whichever display is at (0,0), so this shifts every online display by the target's
    /// origin, in one transaction.
    @concurrent public func setMain(_ id: DisplayID) async throws {
        let online = backend.topology().online.filter { $0.kind != .emptyPipe }
        guard let target = online.first(where: { $0.id == id }) else {
            throw DisplayOperationError.notOnline(id)
        }
        let top = DisplayOrigin(x: 0, y: 0)
        if target.isMain && target.origin == top { return }

        try backend.commit(
            online.map { display in
                .origin(
                    display.id,
                    DisplayOrigin(x: display.origin.x - target.origin.x, y: display.origin.y - target.origin.y)
                )
            }
        )

        let isMain = try await wait(upTo: Self.verifyLimitSeconds) {
            let topology = backend.topology()
            return topology.main?.id == id && topology.display(id)?.origin == top
        }
        guard isMain else { throw DisplayOperationError.notMain(id) }
    }

    /// Returns where the display actually ended up, which macOS may have changed.
    @concurrent public func setPlacement(_ id: DisplayID, _ origin: DisplayOrigin) async throws -> DisplayOrigin {
        guard onlineDisplay(id) != nil else { throw DisplayOperationError.notOnline(id) }
        try backend.commit([.origin(id, origin)])
        try await clock.sleep(seconds: Self.settleSeconds)
        guard let placed = onlineDisplay(id) else { throw DisplayOperationError.notOnline(id) }
        return placed.origin
    }

    /// Checks the online list, because that's the one thing that says it really went off.
    @concurrent public func disconnect(_ id: DisplayID) async throws {
        try backend.setEnabled(id, false)
        let left = try await wait(upTo: Self.disconnectLimitSeconds) {
            !backend.topology().onlineIDs.contains(id)
        }
        guard left else { throw DisplayOperationError.stillOnline(id) }
    }

    /// All of them in one backend transaction, then the same check as for one: none may still read
    /// online after 3 seconds, or this names the first, in the order given, that does. Returns how long
    /// the backend call itself took, by the injected clock, because that call is where macOS sometimes
    /// stalls for 10 seconds. An empty list does nothing.
    @discardableResult
    @concurrent public func disconnect(_ ids: [DisplayID]) async throws -> Double {
        guard !ids.isEmpty else { return 0 }
        let called = clock.now()
        try backend.setEnabled(ids, false)
        let callSeconds = clock.now().timeIntervalSince(called)

        var stillOnline: DisplayID?
        let left = try await wait(upTo: Self.disconnectLimitSeconds) {
            let online = backend.topology().onlineIDs
            stillOnline = ids.first { online.contains($0) }
            return stillOnline == nil
        }
        guard left else { throw DisplayOperationError.stillOnline(stillOnline ?? ids[0]) }
        return callSeconds
    }

    /// `id` has to be the one recorded before the display went off.
    @concurrent public func connect(_ id: DisplayID) async throws {
        try backend.setEnabled(id, true)
        let returned = try await wait(upTo: Self.connectLimitSeconds) {
            onlineDisplay(id) != nil
        }
        guard returned else { throw DisplayOperationError.didNotReturn(id) }
    }

    /// `resolution` is in points. An unspecified resolution stays as it is. An unspecified rate or
    /// scale stays too if this size offers it, and otherwise goes to what's offered, fastest first.
    @concurrent public func selectMode(
        _ id: DisplayID,
        resolution: ScreenSize?,
        refreshHz: Int?,
        hiDPI: Bool?
    ) async throws {
        guard let current = onlineDisplay(id)?.mode else { throw DisplayOperationError.notOnline(id) }

        let size = resolution ?? ScreenSize(w: current.pointsWide, h: current.pointsHigh)
        let offered = backend.modes(of: id).filter { mode in
            mode.pointsWide == size.w && mode.pointsHigh == size.h
                && (hiDPI == nil || mode.isHiDPI == hiDPI)
                && (refreshHz == nil || Self.wholeHz(mode) == refreshHz)
        }
        guard let chosen = Self.closest(to: current, among: offered) else {
            throw DisplayOperationError.noSuchMode(id, Self.describe(size, refreshHz: refreshHz, hiDPI: hiDPI))
        }
        guard !chosen.matches(current) else { return }

        try backend.commit([.mode(id, chosen)])

        let applied = try await wait(upTo: Self.verifyLimitSeconds) {
            onlineDisplay(id)?.mode?.matches(chosen) == true
        }
        guard applied else {
            let wanted = Self.describe(
                ScreenSize(w: chosen.pointsWide, h: chosen.pointsHigh),
                refreshHz: Self.wholeHz(chosen),
                hiDPI: chosen.isHiDPI
            )
            throw DisplayOperationError.modeNotApplied(id, wanted)
        }
    }

    /// A display that has just gone away can read online once, as an empty pipe.
    private func onlineDisplay(_ id: DisplayID) -> DisplaySnapshot? {
        backend.topology().online.first { $0.id == id && $0.kind != .emptyPipe }
    }

    private func wait(upTo limit: Double, until condition: () -> Bool) async throws -> Bool {
        let deadline = clock.now().addingTimeInterval(limit)
        while !condition() {
            guard clock.now() < deadline else { return false }
            try await clock.sleep(seconds: Self.pollSeconds)
        }
        return true
    }

    private static func wholeHz(_ mode: DisplayMode) -> Int {
        Int(mode.refreshHz.rounded())
    }

    private static func closest(to current: DisplayMode, among offered: [DisplayMode]) -> DisplayMode? {
        func rank(_ mode: DisplayMode) -> (Int, Int, Int) {
            (
                mode.isHiDPI == current.isHiDPI ? 1 : 0,
                wholeHz(mode) == wholeHz(current) ? 1 : 0,
                wholeHz(mode)
            )
        }
        return offered.max { rank($0) < rank($1) }
    }

    private static func describe(_ size: ScreenSize, refreshHz: Int?, hiDPI: Bool?) -> String {
        var text = "\(size)"
        if let refreshHz { text += " at \(refreshHz) Hz" }
        if let hiDPI { text += hiDPI ? " HiDPI" : " non-HiDPI" }
        return text
    }
}
