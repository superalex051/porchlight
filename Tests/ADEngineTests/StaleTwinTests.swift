import ADDisplays
import ADModel
import Foundation
import Testing

@testable import ADEngine

/// The M34WQ's stale twin, as the real Mac had one on 2026-11-07: an offline record with its vendor,
/// model and serial on a port it used earlier, with no mode and no UUID, that never comes online. In
/// the desk fixture the M34WQ is ID 4, so the twin is ID 6.
@MainActor
@Suite struct StaleTwinTests {
    private static let earlierPort = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext2@0/IOMobileFramebufferShim"
    private static let twinID: DisplayID = 6

    private func addTwin(_ simulated: SimulatedDisplayBackend) throws {
        let twin = try #require(simulated.scriptStaleTwin(of: m34, registryLocation: Self.earlierPort))
        try #require(twin == Self.twinID)
    }

    @Test func identifiersSkipAStaleTwin() async throws {
        let rig = try DispatcherRig()
        try addTwin(rig.rig.simulated)
        try rig.rig.registry.update(from: rig.rig.simulated.topology())

        let output = try await rig.run("get", "-identifiers", "--json")

        let parsed = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        let envelope = try #require(parsed as? [String: Any])
        let list = try #require(envelope["json"] as? [[String: String]])
        #expect(list.map { $0["displayID"] } == ["2", "4"])
        #expect(list.map { $0["UUID"] } == [lgUUID, m34UUID])
    }

    @Test func aSessionEndsCleanlyWithAStaleTwinListed() async throws {
        let rig = try SessionRig()
        try addTwin(rig.simulated)
        _ = try await rig.session.start(parsec())
        rig.expectMonitorsOff()

        let outcome = try await rig.session.end(client: "parsec", force: false, reason: "test")

        #expect(outcome == EndOutcome())
        rig.expectDeskRestored()
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.count("enable \(Self.twinID)") == 0)
        #expect(rig.countOfPrefix("enable \(Self.twinID) failed") == 0)
    }

    /// The review's wedge: the M34WQ unplugged during the session, its twin still listed. The end has to
    /// verify with the LG back and the M34WQ named as not restored, and leave nothing behind it.
    @Test func anEndWithTheMonitorUnpluggedAndItsTwinListedRestoresTheLGAndWarns() async throws {
        let rig = try SessionRig()
        try addTwin(rig.simulated)
        _ = try await rig.session.start(parsec())
        rig.simulated.removePhysical(m34)

        let outcome = try await rig.session.end(client: "parsec", force: false, reason: "test")

        #expect(outcome == EndOutcome(missing: ["M34WQ"]))
        #expect(outcome.warning == "not restored: M34WQ")
        let topology = rig.simulated.topology()
        #expect(topology.main?.id == lg)
        #expect(topology.display(lg)?.origin == lgOrigin)
        #expect(topology.display(lg)?.mode?.matches(lg120) == true)
        rig.expectNoScreen()
        #expect(try rig.ledger == nil)
        #expect(rig.session.status().state == .idle)
        _ = try await rig.session.start(parsec())
        #expect(rig.session.status().state == .active, "The next guest gets a session")
    }

    @Test func rescueWithNoSessionAndTheMonitorUnpluggedAndItsTwinListedSucceeds() async throws {
        let rig = try SessionRig()
        try addTwin(rig.simulated)
        try rig.registry.update(from: rig.simulated.topology())
        rig.simulated.removePhysical(m34)
        let start = rig.clock.now()

        let outcome = try await rig.session.rescue()

        #expect(outcome == EndOutcome())
        #expect(rig.clock.now().timeIntervalSince(start) < 10)
    }

    /// The hardware run's `rescue` took about 17 seconds with every monitor already on.
    @Test func rescueWithNoSessionAndEveryMonitorOnChangesNothingAndIsQuick() async throws {
        let rig = try SessionRig()
        try addTwin(rig.simulated)
        try rig.registry.update(from: rig.simulated.topology())
        let start = rig.clock.now()

        let outcome = try await rig.session.rescue()

        #expect(outcome == EndOutcome())
        #expect(rig.mutations.isEmpty)
        #expect(rig.clock.now().timeIntervalSince(start) < 1)
    }
}
