import ADDisplays
import ADFoundation
import ADModel
import ADSPI
import Dispatch

/// The real virtual screens. `create` and `reconfigure` crash in a test bundle unless `AD_HIL=1`, so
/// this class gets a build check and attended testing, not unit tests.
///
/// **The process must be running a real `NSApplication`, and this class doesn't start one.** The spike's
/// owner with only `RunLoop.main.run()` got no reconfiguration events and saw an empty mode list for
/// its own screen, so here every `create` would time out.
///
/// A screen lives for as long as its handle does, and `owned` holds the handle. A recreate must not
/// keep a local copy of the old one, or the old screen stays alive beside its replacement.
@MainActor
public final class LiveVirtualScreenProvider: VirtualScreenProviding {
    private struct Owned {
        let token: Int
        let handle: VirtualDisplayHandle
        let limits: VirtualScreenLimits
        /// Nil until `create` hands it out. A screen that ends before then is `create`'s failure to
        /// report, not a termination.
        var screen: ActiveVirtualScreen?
    }

    private static let log = ADLog.logger("virtualscreens")

    public var onScreenTerminated: ((ActiveVirtualScreen) -> Void)?

    private let settler: VirtualScreenSettler
    private var owned: [DisplayID: Owned] = [:]
    private var lastToken = 0

    public init(backend: any DisplayBackend, clock: any ADClock) {
        settler = VirtualScreenSettler(backend: backend, clock: clock)
    }

    public func create(_ spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        TestBundleGuard.preconditionMutationAllowed()

        // The termination handler is set before the display ID exists, so it goes by this instead.
        lastToken += 1
        let token = lastToken
        let handle = try await settler.createRetrying(spec) {
            VirtualDisplayHandle.create(
                name: spec.name,
                vendorID: DisplayClassifier.ownVendor,
                productID: DisplayClassifier.ownProduct,
                serial: spec.serial,
                maxPixelsWide: spec.maxPixelsWide,
                maxPixelsHigh: spec.maxPixelsHigh,
                sizeMM: spec.sizeMM,
                queue: .main,
                onTerminate: { [weak self] in
                    // Not `assumeIsolated`: no live screen has reached this path yet, and a wrong
                    // guess about its thread must not crash the app during a session.
                    Task { @MainActor in self?.systemEnded(token) }
                }
            )
        }

        let id = handle.displayID
        owned[id] = Owned(token: token, handle: handle, limits: VirtualScreenLimits(createdWith: spec))
        do {
            guard handle.apply(modes: Self.modes(of: spec), hiDPI: spec.hiDPI) else {
                throw VirtualScreenError(reason: "macOS refused the settings for virtual screen \(spec.name)")
            }
            let uuid = try await settler.settle(id, to: spec.expectedMode) { owned[id] != nil }
            let screen = ActiveVirtualScreen(displayID: id, uuid: uuid, spec: spec)
            owned[id]?.screen = screen
            Self.log.notice("Created virtual screen \(id), \(spec.looksLike.description, privacy: .public)")
            return screen
        } catch {
            owned[id] = nil
            throw error
        }
    }

    public func reconfigure(_ screen: ActiveVirtualScreen, to spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        TestBundleGuard.preconditionMutationAllowed()

        let id = screen.displayID
        guard let limits = owned[id]?.limits else { throw VirtualScreenError.notOurs(id) }
        guard limits.allowInPlace(spec) else {
            destroy(screen)
            try await settler.waitUntilGone(id)
            return try await create(spec)
        }

        guard owned[id]?.handle.apply(modes: Self.modes(of: spec), hiDPI: spec.hiDPI) == true else {
            throw VirtualScreenError(reason: "macOS refused the settings for virtual screen \(spec.name)")
        }
        let uuid = try await settler.settle(id, to: spec.expectedMode) { owned[id] != nil }
        let updated = ActiveVirtualScreen(displayID: id, uuid: uuid, spec: spec)
        owned[id]?.screen = updated
        Self.log.notice("Virtual screen \(id) is now \(spec.looksLike.description, privacy: .public)")
        return updated
    }

    public func destroy(_ screen: ActiveVirtualScreen) {
        // Dropping the entry drops the handle, and that ends the screen.
        guard owned.removeValue(forKey: screen.displayID) != nil else { return }
        Self.log.notice("Destroyed virtual screen \(screen.displayID)")
    }

    private func systemEnded(_ token: Int) {
        // Nothing to find after a `destroy`, in case the system calls this for a screen we released.
        guard let ended = owned.first(where: { $0.value.token == token }) else { return }
        owned[ended.key] = nil
        Self.log.error("The system ended virtual screen \(ended.key)")
        if let screen = ended.value.screen {
            onScreenTerminated?(screen)
        }
    }

    /// In points, with the rate that goes to `CGVirtualDisplayMode`. HiDPI is the settings' flag.
    private static func modes(of spec: VirtualScreenSpec) -> [(w: Int, h: Int, hz: Double)] {
        spec.declaredModes.map { (w: $0.pointsWide, h: $0.pointsHigh, hz: $0.refreshHz) }
    }
}
