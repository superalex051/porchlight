import ADDisplays
import ADFoundation
import ADModel

/// Virtual screens on a `SimulatedDisplayBackend`, for tests and dry runs. It makes the same decisions
/// and runs the same check as the live provider. The backend places new screens, not this class.
@MainActor
public final class SimulatedVirtualScreenProvider: VirtualScreenProviding {
    private struct Owned {
        let limits: VirtualScreenLimits
        var screen: ActiveVirtualScreen
    }

    /// Makes the next `create` throw, including the one inside a `reconfigure` that recreates.
    public var failNextCreate = false
    /// How many of the next tries at making a screen macOS declines, as it does while it still has a
    /// screen with the same identity to remove. `create` retries within its bound, as the live one does.
    public var declinedCreateTries = 0
    /// Makes the next `reconfigure` throw before it changes anything.
    public var failNextReconfigure = false

    public var onScreenTerminated: ((ActiveVirtualScreen) -> Void)?

    private let backend: SimulatedDisplayBackend
    private let settler: VirtualScreenSettler
    private var owned: [DisplayID: Owned] = [:]

    public init(backend: SimulatedDisplayBackend) {
        self.backend = backend
        settler = VirtualScreenSettler(backend: backend, clock: AutoAdvancingClock())
    }

    public func create(_ spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        if failNextCreate {
            failNextCreate = false
            throw VirtualScreenError(reason: "simulated failure creating \(spec.name)")
        }

        let mode = spec.expectedMode
        let id = try await settler.createRetrying(spec) { () -> DisplayID? in
            guard declinedCreateTries == 0 else {
                declinedCreateTries -= 1
                return nil
            }
            return backend.addVirtual(
                identity: DisplayIdentity(
                    vendor: DisplayClassifier.ownVendor,
                    model: DisplayClassifier.ownProduct,
                    serial: spec.serial,
                    productName: spec.name
                ),
                mode: mode,
                modes: spec.declaredModes
            )
        }
        do {
            let uuid = try await settler.settle(id, to: mode) { true }
            let screen = ActiveVirtualScreen(displayID: id, uuid: uuid, spec: spec)
            owned[id] = Owned(limits: VirtualScreenLimits(createdWith: spec), screen: screen)
            return screen
        } catch {
            backend.removeVirtual(id)
            throw error
        }
    }

    public func reconfigure(_ screen: ActiveVirtualScreen, to spec: VirtualScreenSpec) async throws -> ActiveVirtualScreen {
        if failNextReconfigure {
            failNextReconfigure = false
            throw VirtualScreenError(reason: "simulated failure reconfiguring display \(screen.displayID)")
        }

        let id = screen.displayID
        guard let limits = owned[id]?.limits else { throw VirtualScreenError.notOurs(id) }
        guard limits.allowInPlace(spec) else {
            destroy(screen)
            try await settler.waitUntilGone(id)
            return try await create(spec)
        }

        let mode = spec.expectedMode
        backend.setVirtualMode(id, mode)
        let uuid = try await settler.settle(id, to: mode) { owned[id] != nil }
        let updated = ActiveVirtualScreen(displayID: id, uuid: uuid, spec: spec)
        owned[id]?.screen = updated
        return updated
    }

    public func destroy(_ screen: ActiveVirtualScreen) {
        guard owned.removeValue(forKey: screen.displayID) != nil else { return }
        backend.removeVirtual(screen.displayID)
    }

    /// The system ends this screen: it leaves the backend, and `onScreenTerminated` gets it as it last
    /// was, whichever value is passed here. A screen that's already gone is ignored.
    public func simulateTermination(of screen: ActiveVirtualScreen) {
        guard let ended = owned.removeValue(forKey: screen.displayID) else { return }
        backend.removeVirtual(screen.displayID)
        onScreenTerminated?(ended.screen)
    }
}
