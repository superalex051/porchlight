import Carbon.HIToolbox
import Dispatch
import Synchronization
import Testing
@testable import ADInput

// No test here registers a real hotkey: that would grab the shortcut on this Mac while it runs.
// The Carbon tests build an event in memory and hand it straight to the trampoline.

private final class PressLog: Sendable {
    private let names = Mutex<[String]>([])

    var all: [String] { names.withLock { $0 } }

    func record(_ name: String) {
        names.withLock { $0.append(name) }
    }
}

private struct InjectedFailure: Error, Equatable {}

@Test func emergencyKeysAreExact() {
    let modifiers = UInt32(controlKey | optionKey | cmdKey)
    #expect(modifiers == 6400)
    #expect(EmergencyHotkeys.rescue == Hotkey(keyCode: 53, modifiers: modifiers))
    #expect(EmergencyHotkeys.restart == Hotkey(keyCode: 15, modifiers: modifiers))
    #expect(EmergencyHotkeys.quit == Hotkey(keyCode: 12, modifiers: modifiers))
}

@Test func registersAllThreeAndFires() throws {
    let registry = FakeHotkeyRegistry()
    let log = PressLog()

    try EmergencyHotkeys.register(
        on: registry,
        rescue: { log.record("rescue") },
        restart: { log.record("restart") },
        quit: { log.record("quit") }
    )

    #expect(registry.registered == [EmergencyHotkeys.rescue, EmergencyHotkeys.restart, EmergencyHotkeys.quit])
    #expect(log.all.isEmpty)

    registry.fire(EmergencyHotkeys.quit)
    registry.fire(EmergencyHotkeys.rescue)
    registry.fire(EmergencyHotkeys.restart)
    #expect(log.all == ["quit", "rescue", "restart"])
}

@Test func registerFailurePropagates() {
    let registry = FakeHotkeyRegistry()
    registry.failure = (EmergencyHotkeys.restart, InjectedFailure())

    #expect(throws: InjectedFailure()) {
        try EmergencyHotkeys.register(on: registry, rescue: {}, restart: {}, quit: {})
    }
}

/// The rescue key has to work even if another shortcut can't be registered, and the other way round.
@Test func oneFailureDoesNotCostTheOtherKeys() {
    let registry = FakeHotkeyRegistry()
    registry.failure = (EmergencyHotkeys.restart, InjectedFailure())
    let log = PressLog()

    #expect(throws: InjectedFailure()) {
        try EmergencyHotkeys.register(
            on: registry,
            rescue: { log.record("rescue") },
            restart: { log.record("restart") },
            quit: { log.record("quit") }
        )
    }

    #expect(registry.registered == [EmergencyHotkeys.rescue, EmergencyHotkeys.quit])
    registry.fire(EmergencyHotkeys.rescue)
    registry.fire(EmergencyHotkeys.restart)
    registry.fire(EmergencyHotkeys.quit)
    #expect(log.all == ["rescue", "quit"])
}

// MARK: - Carbon trampoline

/// An empty hotkey press, built without registering anything.
private func makeEmptyHotkeyEvent() throws -> EventRef {
    var created: EventRef?
    let status = CreateEvent(
        nil,
        OSType(kEventClassKeyboard),
        UInt32(kEventHotKeyPressed),
        0,
        EventAttributes(kEventAttributeNone),
        &created
    )
    try #require(status == noErr)
    return try #require(created)
}

private func deliver(signature: OSType, id: UInt32, to dispatcher: HotkeyDispatcher) throws -> OSStatus {
    try deliver(signature: signature, id: id, userData: Unmanaged.passUnretained(dispatcher).toOpaque())
}

/// Delivers one press through the real trampoline and returns what it told Carbon. The event only
/// exists in memory: it goes straight to the function and is never posted anywhere.
private func deliver(signature: OSType, id: UInt32, userData: UnsafeMutableRawPointer) throws -> OSStatus {
    let event = try makeEmptyHotkeyEvent()
    defer { ReleaseEvent(event) }

    var hotkeyID = EventHotKeyID(signature: signature, id: id)
    let status = SetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        MemoryLayout<EventHotKeyID>.size,
        &hotkeyID
    )
    try #require(status == noErr)

    return hotkeyEventTrampoline(nil, event, userData)
}

@Test(.timeLimit(.minutes(1))) @MainActor func trampolineRunsTheActionForThatPress() async throws {
    let dispatcher = HotkeyDispatcher()
    defer { dispatcher.finish() }
    let (runs, run) = AsyncStream.makeStream(of: String.self)
    var nextRun = runs.makeAsyncIterator()
    dispatcher.setAction({ run.yield("first") }, for: 1)
    dispatcher.setAction({ run.yield("second") }, for: 2)

    #expect(try deliver(signature: hotkeySignature, id: 2, to: dispatcher) == noErr)
    #expect(await nextRun.next() == "second")

    #expect(try deliver(signature: hotkeySignature, id: 1, to: dispatcher) == noErr)
    #expect(await nextRun.next() == "first")
}

/// The callback runs inside Carbon's event dispatch, so it must return before any action runs.
/// If it ran the action itself, the action would wait out its whole timeout here.
@Test(.timeLimit(.minutes(1))) @MainActor func trampolineReturnsBeforeTheActionRuns() async throws {
    let dispatcher = HotkeyDispatcher()
    defer { dispatcher.finish() }
    let (runs, run) = AsyncStream.makeStream(of: String.self)
    var nextRun = runs.makeAsyncIterator()
    let callbackReturned = DispatchSemaphore(value: 0)
    dispatcher.setAction({
        let waited = callbackReturned.wait(timeout: .now() + 10)
        run.yield(waited == .success ? "after the callback" : "inside the callback")
    }, for: 1)

    #expect(try deliver(signature: hotkeySignature, id: 1, to: dispatcher) == noErr)
    callbackReturned.signal()

    #expect(await nextRun.next() == "after the callback")
}

/// Presses run in order, so if either ignored press got through, its action would come out first.
@Test(.timeLimit(.minutes(1))) @MainActor func trampolineIgnoresPressesThatAreNotOurs() async throws {
    let dispatcher = HotkeyDispatcher()
    defer { dispatcher.finish() }
    let (runs, run) = AsyncStream.makeStream(of: String.self)
    var nextRun = runs.makeAsyncIterator()
    dispatcher.setAction({ run.yield("wrong signature") }, for: 2)
    dispatcher.setAction({ run.yield("ours") }, for: 1)

    #expect(try deliver(signature: hotkeySignature &+ 1, id: 2, to: dispatcher) == OSStatus(eventNotHandledErr))
    #expect(try deliver(signature: hotkeySignature, id: 99, to: dispatcher) == noErr)
    #expect(try deliver(signature: hotkeySignature, id: 1, to: dispatcher) == noErr)

    #expect(await nextRun.next() == "ours")
}

@Test @MainActor func trampolineRejectsAnEventWithNoHotkeyID() throws {
    let dispatcher = HotkeyDispatcher()
    defer { dispatcher.finish() }
    let event = try makeEmptyHotkeyEvent()
    defer { ReleaseEvent(event) }

    let result = hotkeyEventTrampoline(nil, event, Unmanaged.passUnretained(dispatcher).toOpaque())

    #expect(result == OSStatus(eventNotHandledErr))
}

// MARK: - CarbonHotkeyRegistry, with Carbon scripted

private let exclusive: OptionBits = 1
private let nonExclusive: OptionBits = 0
private let hotkeyExists: OSStatus = -9878
private let someKey = Hotkey(keyCode: 53, modifiers: 6400)
private let otherKey = Hotkey(keyCode: 12, modifiers: 6400)

/// Stands in for Carbon. `answer` decides each registration, and every ref it hands out is made up,
/// so nothing here can reach a real shortcut.
private final class FakeCarbon: CarbonHotkeyCalling {
    struct RegisterCall: Equatable {
        var hotkey: Hotkey
        var id: UInt32
        var options: OptionBits
    }

    var answer: (Hotkey, OptionBits) -> OSStatus = { _, _ in noErr }
    var installStatus: OSStatus = noErr
    private(set) var installCount = 0
    private(set) var userData: UnsafeMutableRawPointer?
    private(set) var registerCalls: [RegisterCall] = []
    private(set) var handedOut: [EventHotKeyRef] = []
    private(set) var unregistered: [EventHotKeyRef] = []
    private(set) var removedHandlers = 0

    func installHandler(userData: UnsafeMutableRawPointer) -> (status: OSStatus, handler: EventHandlerRef?) {
        installCount += 1
        guard installStatus == noErr else { return (installStatus, nil) }
        self.userData = userData
        return (noErr, OpaquePointer(bitPattern: 0x1000))
    }

    func removeHandler(_ handler: EventHandlerRef) {
        removedHandlers += 1
    }

    func registerHotkey(_ hotkey: Hotkey, id: EventHotKeyID, options: OptionBits) -> (status: OSStatus, ref: EventHotKeyRef?) {
        registerCalls.append(RegisterCall(hotkey: hotkey, id: id.id, options: options))
        let status = answer(hotkey, options)
        guard status == noErr, let ref = OpaquePointer(bitPattern: 0x2000 + registerCalls.count) else {
            return (status, nil)
        }
        handedOut.append(ref)
        return (noErr, ref)
    }

    func unregisterHotkey(_ ref: EventHotKeyRef) {
        unregistered.append(ref)
    }

    /// What Carbon would do on a press, through the real trampoline.
    func press(id: UInt32) throws -> OSStatus {
        try deliver(signature: hotkeySignature, id: id, userData: try #require(userData))
    }
}

@Test @MainActor func exclusiveIsTriedFirstAndIsEnoughWhenFree() throws {
    let carbon = FakeCarbon()
    let errors = PressLog()
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })

    try registry.register(someKey) {}

    #expect(carbon.registerCalls == [.init(hotkey: someKey, id: 1, options: exclusive)])
    #expect(errors.all.isEmpty)
    withExtendedLifetime(registry) {}
}

/// A non-exclusive registration succeeds even under another process's exclusive one, so the key
/// stays registered for when that process lets go, and the app hears that it may not work.
@Test(.timeLimit(.minutes(1))) @MainActor func conflictFallsBackToNonExclusiveAndIsReported() async throws {
    let carbon = FakeCarbon()
    carbon.answer = { _, options in options == exclusive ? hotkeyExists : noErr }
    let errors = PressLog()
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })
    let (runs, run) = AsyncStream.makeStream(of: String.self)
    var nextRun = runs.makeAsyncIterator()

    #expect(throws: HotkeyError.conflict(someKey)) {
        try registry.register(someKey) { run.yield("pressed") }
    }

    #expect(carbon.registerCalls == [
        .init(hotkey: someKey, id: 1, options: exclusive),
        .init(hotkey: someKey, id: 1, options: nonExclusive),
    ])
    #expect(errors.all.count == 1)
    #expect(errors.all.first?.contains("key code 53") == true)

    #expect(try carbon.press(id: 1) == noErr)
    #expect(await nextRun.next() == "pressed")
    withExtendedLifetime(registry) {}
}

@Test @MainActor func otherFailuresDoNotFallBack() {
    let carbon = FakeCarbon()
    carbon.answer = { _, _ in -50 }
    let errors = PressLog()
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })

    #expect(throws: HotkeyError.registrationFailed(someKey, status: -50)) {
        try registry.register(someKey) {}
    }

    #expect(carbon.registerCalls == [.init(hotkey: someKey, id: 1, options: exclusive)])
    #expect(errors.all.isEmpty)
}

/// With no registration at all, the key can't work even after the other process lets go, so this
/// must not read as the softer conflict.
@Test @MainActor func aFailedFallbackIsARegistrationFailure() {
    let carbon = FakeCarbon()
    carbon.answer = { _, _ in hotkeyExists }
    let errors = PressLog()
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })

    #expect(throws: HotkeyError.registrationFailed(someKey, status: hotkeyExists)) {
        try registry.register(someKey) {}
    }

    #expect(carbon.registerCalls.map(\.options) == [exclusive, nonExclusive])
    #expect(carbon.handedOut.isEmpty)
    #expect(errors.all.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func aConflictOnOneEmergencyKeyLeavesAllThreeRegistered() async throws {
    let carbon = FakeCarbon()
    carbon.answer = { hotkey, options in
        hotkey == EmergencyHotkeys.rescue && options == exclusive ? hotkeyExists : noErr
    }
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { _ in })
    let (runs, run) = AsyncStream.makeStream(of: String.self)
    var nextRun = runs.makeAsyncIterator()

    #expect(throws: HotkeyError.conflict(EmergencyHotkeys.rescue)) {
        try EmergencyHotkeys.register(
            on: registry,
            rescue: { run.yield("rescue") },
            restart: { run.yield("restart") },
            quit: { run.yield("quit") }
        )
    }

    #expect(carbon.registerCalls == [
        .init(hotkey: EmergencyHotkeys.rescue, id: 1, options: exclusive),
        .init(hotkey: EmergencyHotkeys.rescue, id: 1, options: nonExclusive),
        .init(hotkey: EmergencyHotkeys.restart, id: 2, options: exclusive),
        .init(hotkey: EmergencyHotkeys.quit, id: 3, options: exclusive),
    ])

    #expect(try carbon.press(id: 1) == noErr)
    #expect(await nextRun.next() == "rescue")
    #expect(try carbon.press(id: 2) == noErr)
    #expect(await nextRun.next() == "restart")
    #expect(try carbon.press(id: 3) == noErr)
    #expect(await nextRun.next() == "quit")
    withExtendedLifetime(registry) {}
}

@Test @MainActor func handlerIsInstalledOnceAndAFailedInstallIsRetried() throws {
    let carbon = FakeCarbon()
    carbon.installStatus = -1
    let registry = CarbonHotkeyRegistry(carbon: carbon, logError: { _ in })

    #expect(throws: HotkeyError.handlerInstallFailed(status: -1)) {
        try registry.register(someKey) {}
    }
    #expect(carbon.registerCalls.isEmpty)

    carbon.installStatus = noErr
    try registry.register(someKey) {}
    try registry.register(otherKey) {}

    #expect(carbon.installCount == 2)
    #expect(carbon.registerCalls.map(\.hotkey) == [someKey, otherKey])
    withExtendedLifetime(registry) {}
}

@Test @MainActor func droppingTheRegistryRemovesItsKeysAndLogsAnError() throws {
    let carbon = FakeCarbon()
    let errors = PressLog()
    var registry: CarbonHotkeyRegistry? = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })

    try registry?.register(someKey) {}
    try registry?.register(otherKey) {}
    #expect(errors.all.isEmpty)

    registry = nil

    #expect(carbon.unregistered == carbon.handedOut)
    #expect(carbon.unregistered.count == 2)
    #expect(carbon.removedHandlers == 1)
    #expect(errors.all.count == 1)
    #expect(errors.all.first?.contains("2") == true)
}

@Test @MainActor func droppingARegistryWithNoKeysLogsNothing() {
    let carbon = FakeCarbon()
    let errors = PressLog()
    var registry: CarbonHotkeyRegistry? = CarbonHotkeyRegistry(carbon: carbon, logError: { errors.record($0) })
    #expect(registry != nil)

    registry = nil

    #expect(errors.all.isEmpty)
    #expect(carbon.unregistered.isEmpty)
    #expect(carbon.removedHandlers == 0)
}
