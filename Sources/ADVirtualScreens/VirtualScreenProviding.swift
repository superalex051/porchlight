import ADDisplays
import ADFoundation
import ADModel
import Foundation

public struct VirtualScreenError: Error, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    static func notOurs(_ id: DisplayID) -> VirtualScreenError {
        VirtualScreenError(reason: "display \(id) is not a virtual screen this provider has")
    }
}

/// The seam between the session and the virtual screens.
@MainActor
public protocol VirtualScreenProviding: AnyObject {
    /// Called on the main actor when the system ends a screen this provider handed out, with the
    /// screen as it last was, so its owner can create it again. A `destroy` doesn't call it.
    var onScreenTerminated: ((ActiveVirtualScreen) -> Void)? { get set }

    /// Returns once the screen is active in the spec's mode. While macOS declines to make it, this
    /// tries again for up to about 4 seconds. On a throw, no screen is left behind.
    func create(_ spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen

    /// Changes the screen in place if the new mode fits the max size it was created with. If it
    /// doesn't, or the new spec is for another name or serial, which also can't change, this destroys
    /// the screen and creates another, so use the ID of the returned value from here on.
    ///
    /// The old screen goes first, and this waits up to 2 seconds for macOS to finish removing it, so if
    /// creating the new one throws, neither is left. If an in-place change throws, the screen is still
    /// there, and its current mode isn't known.
    func reconfigure(_ screen: ActiveVirtualScreen, to spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen

    /// Ends the screen. A screen that's already gone is ignored.
    func destroy(_ screen: ActiveVirtualScreen)
}

/// What a virtual screen gets at creation and can't change later. These can't come from
/// `ActiveVirtualScreen.spec`, which follows each resize: a screen created at 2560x1600 and resized
/// to 1728x1080 still has the larger max.
struct VirtualScreenLimits {
    private let name: String
    private let serial: UInt32
    private let maxPixelsWide: Int
    private let maxPixelsHigh: Int

    init(createdWith spec: VirtualScreenSpec) {
        name = spec.name
        serial = spec.serial
        maxPixelsWide = spec.maxPixelsWide
        maxPixelsHigh = spec.maxPixelsHigh
    }

    /// Goes by the pixels the new mode needs. A 1x 2560x1440 fits a 4032x2520 screen, even though a
    /// screen created for it would get a larger max.
    func allowInPlace(_ spec: VirtualScreenSpec) -> Bool {
        let mode = spec.expectedMode
        return spec.name == name
            && spec.serial == serial
            && mode.pixelsWide <= maxPixelsWide
            && mode.pixelsHigh <= maxPixelsHigh
    }
}

/// The spec's check after a create or a resize. Both providers run it, so a test on the simulator gets
/// the answer the live provider would give, and this part of the live provider has unit tests.
struct VirtualScreenSettler {
    static let timeout: Double = 5
    static let pollInterval: Double = 0.25

    /// A screen normally reaches its mode by itself: the spike's took about a second. A commit that
    /// lands while it's still changing is one more reconfiguration for nothing, so it waits this long.
    static let selectAfter: Double = 2
    static let selectRetryInterval: Double = 1
    static let goneTimeout: Double = 2
    static let createTimeout: Double = 4
    static let createTries = 8
    static let createBackoff: Double = 0.25

    private static let log = ADLog.logger("virtualscreens")

    let backend: any DisplayBackend
    let clock: any ADClock

    /// Polls until the display is active and its current mode matches, selecting the mode if the
    /// display offers it but stays in another. Returns the display's UUID.
    ///
    /// Runs on the main actor, as both providers do. Its waits suspend and its commit hops off, so the
    /// main thread keeps delivering the display's reconfiguration events.
    ///
    /// - Parameter isStillOurs: False once the screen has ended, which stops the wait.
    @MainActor
    func settle(_ id: DisplayID, to mode: DisplayMode, isStillOurs: () -> Bool) async throws -> String {
        let start = clock.now()
        var selectAt = Self.selectAfter
        var selectFailure: String?

        while true {
            guard isStillOurs() else {
                throw VirtualScreenError(reason: "display \(id) ended before it was active in \(Self.describe(mode))")
            }

            let display = backend.topology().display(id)
            let isCurrent = display?.mode?.matches(mode) == true
            if let display, display.isActive, isCurrent, let uuid = display.identity.uuid {
                return uuid
            }

            let elapsed = clock.now().timeIntervalSince(start)
            guard elapsed < Self.timeout else {
                let why = selectFailure.map { "; selecting it failed: \($0)" } ?? ""
                throw VirtualScreenError(
                    reason: "display \(id) was not active in \(Self.describe(mode)) after \(Int(Self.timeout)) seconds\(why)"
                )
            }

            if !isCurrent, elapsed >= selectAt, backend.modes(of: id).contains(where: { $0.matches(mode) }) {
                selectAt = elapsed + Self.selectRetryInterval
                do {
                    try await Self.commit([.mode(id, mode)], on: backend)
                    selectFailure = nil
                    continue
                } catch let error as DisplayBackendError {
                    selectFailure = "\(error.message) (\(error.code))"
                }
            }

            try await clock.sleep(seconds: Self.pollInterval)
        }
    }

    /// Waits for a released screen to leave the display list. A release only lets go on this side, and
    /// WindowServer removes the screen later. A new screen with the same identity must not race that,
    /// because the late removal could take the new one too.
    ///
    /// Returns false, after logging it, if the ID is still listed at the timeout. The caller goes ahead
    /// and creates anyway, because stopping there would be sure to leave no screen at all.
    @MainActor
    @discardableResult
    func waitUntilGone(_ id: DisplayID) async throws -> Bool {
        let start = clock.now()
        while backend.topology().display(id) != nil {
            guard clock.now().timeIntervalSince(start) < Self.goneTimeout else {
                Self.log.error("Display \(id) is still listed \(Int(Self.goneTimeout)) seconds after its release, so the new screen is being created beside it")
                return false
            }
            try await clock.sleep(seconds: Self.pollInterval)
        }
        return true
    }

    /// Makes a screen, trying again while macOS declines. It does that while it still has a screen
    /// with the same vendor, product and serial to remove: on the real Mac, a relaunch 0.2 s after a
    /// `kill -9` got nil, and one 0.5 s after got a screen. Before each new try, this waits for any
    /// display with that identity to leave the list, then waits `createBackoff` more. While the
    /// fallback is up the list shows nothing else, so then the backoff alone spaces the tries.
    ///
    /// Stops after `createTries` tries or once `createTimeout` has passed, whichever comes first, and
    /// throws the same error a single failed try used to.
    ///
    /// - Parameter attempt: One try. Nil means macOS declined.
    @MainActor
    func createRetrying<Made>(_ spec: VirtualScreenSpec, attempt: () -> Made?) async throws -> Made {
        let deadline = clock.now().addingTimeInterval(Self.createTimeout)
        for tryNumber in 1...Self.createTries {
            if let made = attempt() {
                if tryNumber > 1 {
                    Self.log.notice("macOS created \(spec.name, privacy: .public) on try \(tryNumber)")
                }
                return made
            }
            guard tryNumber < Self.createTries, clock.now() < deadline else { break }
            Self.log.error("macOS did not create \(spec.name, privacy: .public) on try \(tryNumber) of \(Self.createTries), so this waits for any screen with its identity to go and tries again")
            while clock.now() < deadline, backend.topology().displays.contains(where: { Self.hasIdentity(of: spec, $0) }) {
                try await clock.sleep(seconds: Self.pollInterval)
            }
            try await clock.sleep(seconds: Self.createBackoff)
        }
        throw VirtualScreenError(reason: "macOS did not create the virtual screen \(spec.name)")
    }

    private static func hasIdentity(of spec: VirtualScreenSpec, _ display: DisplaySnapshot) -> Bool {
        display.identity.vendor == DisplayClassifier.ownVendor
            && display.identity.model == DisplayClassifier.ownProduct
            && display.identity.serial == spec.serial
    }

    /// A commit can block for about 10 seconds, so it must not run on the main actor. While it runs,
    /// the owner's main thread still has to deliver the display's reconfiguration events.
    @concurrent
    private static func commit(_ changes: [DisplayChange], on backend: any DisplayBackend) async throws {
        try backend.commit(changes)
    }

    private static func describe(_ mode: DisplayMode) -> String {
        "\(mode.pointsWide)x\(mode.pointsHigh) (\(mode.pixelsWide)x\(mode.pixelsHigh) pixels)"
            + " at \(Int(mode.refreshHz.rounded())) Hz"
    }
}
