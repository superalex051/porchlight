import ADFoundation
import Carbon.HIToolbox
import Dispatch
import Synchronization

/// A global shortcut in Carbon's terms: a virtual key code and a modifier mask.
public struct Hotkey: Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public protocol HotkeyRegistering: AnyObject {
    /// `action` can run on any thread, one press at a time, so it should hand its work to the actor
    /// that owns it and return. A throw doesn't always mean the key is unregistered: see
    /// `HotkeyError.conflict`.
    func register(_ hotkey: Hotkey, action: @escaping @Sendable () -> Void) throws
}

public enum HotkeyError: Error, Equatable {
    case handlerInstallFailed(status: Int32)
    case registrationFailed(Hotkey, status: Int32)
    /// The key is registered, but another process holds the same combination. If that process holds
    /// it exclusively, presses won't arrive until it lets go, so this key may not work.
    case conflict(Hotkey)
}

/// Stamped on every hotkey we register, so the callback can recognize our own presses. Spells `ADHK`.
let hotkeySignature: OSType = 0x4144_484B

/// The Carbon callback. It runs inside Carbon's event dispatch, so it only copies the hotkey ID out
/// of the event and returns. `userData` is the `HotkeyDispatcher`, which outlives the handler.
func hotkeyEventTrampoline(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }

    Unmanaged<HotkeyDispatcher>.fromOpaque(userData).takeUnretainedValue().post(id.id)
    return noErr
}

/// Carries presses out of the Carbon callback. A task of its own runs the actions in press order,
/// off the main thread, until `finish` is called.
final class HotkeyDispatcher: Sendable {
    private let actions = Mutex<[UInt32: @Sendable () -> Void]>([:])
    private let presses: AsyncStream<UInt32>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: UInt32.self)
        presses = continuation
        Task.detached(priority: .userInitiated) { [self] in
            for await id in stream {
                let action = actions.withLock { $0[id] }
                action?()
            }
        }
    }

    func setAction(_ action: @escaping @Sendable () -> Void, for id: UInt32) {
        actions.withLock { $0[id] = action }
    }

    func post(_ id: UInt32) {
        presses.yield(id)
    }

    func finish() {
        presses.finish()
    }
}

/// Registers global shortcuts through Carbon, which needs no permission. Carbon's calls aren't
/// thread safe, so use this on the main thread only. Presses arrive through the main run loop, so
/// the process also needs a running `NSApplication`.
///
/// Keep this registry for as long as the app runs. Releasing it removes every key it registered,
/// so `EmergencyHotkeys.register(on: CarbonHotkeyRegistry(), ...)` leaves no keys behind. That is
/// logged as an error, because the app itself keeps running without its way out.
public final class CarbonHotkeyRegistry: HotkeyRegistering {
    private let carbon: any CarbonHotkeyCalling
    private let logError: @Sendable (String) -> Void
    private let dispatcher = HotkeyDispatcher()
    private var handler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    public convenience init() {
        self.init(carbon: LiveCarbonHotkeyCalls()) { message in
            ADLog.logger("hotkeys").error("\(message, privacy: .public)")
        }
    }

    init(carbon: any CarbonHotkeyCalling, logError: @escaping @Sendable (String) -> Void) {
        self.carbon = carbon
        self.logError = logError
    }

    deinit {
        if !hotkeys.isEmpty {
            logError("Hotkey registry released, removing every hotkey it held (\(hotkeys.count)). It must live as long as the app.")
        }
        for hotkey in hotkeys {
            carbon.unregisterHotkey(hotkey)
        }
        if let handler {
            carbon.removeHandler(handler)
        }
        dispatcher.finish()
    }

    public func register(_ hotkey: Hotkey, action: @escaping @Sendable () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try installHandlerIfNeeded()

        let id = EventHotKeyID(signature: hotkeySignature, id: nextID)
        // Exclusive first, because only that proves presses will arrive. A non-exclusive request
        // succeeds even while another process holds the keys exclusively, and then gets no presses
        // until that process lets go.
        var result = carbon.registerHotkey(hotkey, id: id, options: OptionBits(kEventHotKeyExclusive))
        let isConflict = result.status == OSStatus(eventHotKeyExistsErr)
        if isConflict {
            // Register anyway, so the key starts working as soon as the other process lets go.
            result = carbon.registerHotkey(hotkey, id: id, options: OptionBits(kEventHotKeyNoOptions))
        }
        guard result.status == noErr, let registered = result.ref else {
            throw HotkeyError.registrationFailed(hotkey, status: result.status)
        }

        // A press can't arrive before this, because presses come through this thread's run loop.
        dispatcher.setAction(action, for: id.id)
        hotkeys.append(registered)
        nextID += 1

        if isConflict {
            logError(
                "Hotkey with key code \(hotkey.keyCode) and modifiers \(hotkey.modifiers) is held by another "
                    + "process, so it may not work until that process lets go."
            )
            throw HotkeyError.conflict(hotkey)
        }
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }

        let result = carbon.installHandler(userData: Unmanaged.passUnretained(dispatcher).toOpaque())
        guard result.status == noErr else {
            throw HotkeyError.handlerInstallFailed(status: result.status)
        }
        handler = result.handler
    }
}

/// The Carbon calls `CarbonHotkeyRegistry` makes, so tests can script Carbon's answers without
/// grabbing a real shortcut on this Mac.
protocol CarbonHotkeyCalling {
    func installHandler(userData: UnsafeMutableRawPointer) -> (status: OSStatus, handler: EventHandlerRef?)
    func removeHandler(_ handler: EventHandlerRef)
    func registerHotkey(_ hotkey: Hotkey, id: EventHotKeyID, options: OptionBits) -> (status: OSStatus, ref: EventHotKeyRef?)
    func unregisterHotkey(_ ref: EventHotKeyRef)
}

struct LiveCarbonHotkeyCalls: CarbonHotkeyCalling {
    func installHandler(userData: UnsafeMutableRawPointer) -> (status: OSStatus, handler: EventHandlerRef?) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventTrampoline,
            1,
            &eventType,
            userData,
            &handler
        )
        return (status, handler)
    }

    func removeHandler(_ handler: EventHandlerRef) {
        RemoveEventHandler(handler)
    }

    func registerHotkey(_ hotkey: Hotkey, id: EventHotKeyID, options: OptionBits) -> (status: OSStatus, ref: EventHotKeyRef?) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            options,
            &ref
        )
        return (status, ref)
    }

    func unregisterHotkey(_ ref: EventHotKeyRef) {
        UnregisterEventHotKey(ref)
    }
}

/// A test double. Read `registered` for what was registered and call `fire` to press a key. Set
/// `failure` to make `register` throw for one hotkey, which then doesn't count as registered.
public final class FakeHotkeyRegistry: HotkeyRegistering {
    public var failure: (hotkey: Hotkey, error: any Error)?
    public private(set) var registered: [Hotkey] = []
    private var actions: [(hotkey: Hotkey, action: @Sendable () -> Void)] = []

    public init() {}

    public func register(_ hotkey: Hotkey, action: @escaping @Sendable () -> Void) throws {
        if let failure, failure.hotkey == hotkey {
            throw failure.error
        }
        registered.append(hotkey)
        actions.append((hotkey, action))
    }

    /// Runs the action on this thread, and does nothing for a hotkey that isn't registered.
    public func fire(_ hotkey: Hotkey) {
        actions.first { $0.hotkey == hotkey }?.action()
    }
}
