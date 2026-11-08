import ADModel
import ADSafety
import Testing

private func snapshot(
    id: DisplayID,
    kind: DisplayKind,
    isOnline: Bool = true,
    isActive: Bool = true,
    isAsleep: Bool = false
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        identity: DisplayIdentity(vendor: 1, model: 2, serial: 3),
        kind: kind,
        isOnline: isOnline,
        isActive: isActive,
        isMain: false,
        isAsleep: isAsleep,
        origin: DisplayOrigin(x: 0, y: 0)
    )
}

private func refusal(
    _ displays: [DisplaySnapshot],
    disconnecting: Set<DisplayID>,
    inProtectedSession: Bool = false
) -> SafetyRefusal? {
    let result = NeverZeroRule.check(
        topology: Topology(displays: displays),
        disconnecting: disconnecting,
        inProtectedSession: inProtectedSession
    )
    switch result {
    case .success: return nil
    case .failure(let refusal): return refusal
    }
}

@Test func lastPhysicalIsRefusedOutsideSession() {
    let desk = [snapshot(id: 2, kind: .physical), snapshot(id: 4, kind: .physical)]

    #expect(refusal(desk, disconnecting: [4]) == nil)
    #expect(refusal(desk, disconnecting: [2]) == nil)
    #expect(refusal(desk, disconnecting: [2, 4]) != nil)
    #expect(refusal([desk[0]], disconnecting: [2]) != nil)
}

@Test func ownVirtualDoesNotCountOutsideSession() {
    let displays = [snapshot(id: 2, kind: .physical), snapshot(id: 9, kind: .ownVirtual)]

    #expect(!NeverZeroRule.counts(displays[1], inProtectedSession: false))
    // A virtual screen made by hand doesn't make the last monitor safe to turn off.
    #expect(refusal(displays, disconnecting: [2], inProtectedSession: false) != nil)
}

@Test func ownVirtualCountsInsideProtectedSession() {
    let displays = [
        snapshot(id: 2, kind: .physical),
        snapshot(id: 4, kind: .physical),
        snapshot(id: 9, kind: .ownVirtual),
    ]

    #expect(NeverZeroRule.counts(displays[2], inProtectedSession: true))
    #expect(refusal(displays, disconnecting: [2, 4], inProtectedSession: true) == nil)
    // Taking away the screen as well leaves nothing, even in a session.
    #expect(refusal(displays, disconnecting: [2, 4, 9], inProtectedSession: true) != nil)
}

@Test func fallbackAndParsecNeverCount() {
    for kind in [DisplayKind.osFallback, .parsecVirtual, .otherVirtual, .emptyPipe] {
        let display = snapshot(id: 7, kind: kind)
        #expect(!NeverZeroRule.counts(display, inProtectedSession: false), "\(kind)")
        #expect(!NeverZeroRule.counts(display, inProtectedSession: true), "\(kind)")

        // It's still there after the plan, and the plan is still refused.
        let displays = [snapshot(id: 2, kind: .physical), display]
        #expect(refusal(displays, disconnecting: [2], inProtectedSession: true) != nil, "\(kind)")
    }
}

@Test func sleepingPhysicalCounts() {
    let asleep = snapshot(id: 2, kind: .physical, isOnline: true, isActive: false, isAsleep: true)

    #expect(NeverZeroRule.counts(asleep, inProtectedSession: false))

    let displays = [asleep, snapshot(id: 4, kind: .physical)]
    #expect(refusal(displays, disconnecting: [4]) == nil)
}

@Test func offlineDisplaysDoNotCount() {
    let offlinePhysical = snapshot(id: 2, kind: .physical, isOnline: false, isActive: false)
    let offlineScreen = snapshot(id: 9, kind: .ownVirtual, isOnline: false, isActive: false)

    #expect(!NeverZeroRule.counts(offlinePhysical, inProtectedSession: false))
    #expect(!NeverZeroRule.counts(offlineScreen, inProtectedSession: true))

    let displays = [offlinePhysical, offlineScreen, snapshot(id: 4, kind: .physical)]
    #expect(refusal(displays, disconnecting: [4], inProtectedSession: true) != nil)
}

@Test func emptyTopologyIsRefused() {
    #expect(refusal([], disconnecting: []) != nil)
}

@Test func disconnectingAnUnknownIDChangesNothing() {
    let displays = [snapshot(id: 2, kind: .physical)]
    #expect(refusal(displays, disconnecting: [99]) == nil)
}

@Test func refusalReasonIsExact() {
    let result = refusal([snapshot(id: 2, kind: .physical)], disconnecting: [2])
    #expect(result?.reason == "would leave no working display")
    #expect(result == SafetyRefusal(reason: "would leave no working display"))
}
