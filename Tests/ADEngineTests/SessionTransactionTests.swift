import ADDisplays
import ADFoundation
import ADModel
import Foundation
import Testing

@testable import ADEngine

/// Porch Light spec section 4.3: a session turns its monitors off in one display transaction, because
/// turning the last one off in a transaction of its own sometimes stalled for 10 seconds, and it falls
/// back to one at a time if the transaction fails.
@MainActor
@Suite struct SessionTransactionTests {
    private static let fallbackLine =
        "turning the monitors off together failed (scripted failure of the transaction), so they go one at a time"

    private func started() async throws -> SessionRig {
        let rig = try SessionRig()
        _ = try await rig.session.start(parsec())
        return rig
    }

    // MARK: Start

    @Test func startTurnsBothMonitorsOffInOneTransaction() async throws {
        let rig = try SessionRig()

        let status = try await rig.session.start(parsec())

        #expect(rig.simulated.switchTransactions == ["disable \(m34) \(lg)"], "One call, old main last")
        rig.expectMonitorsOff()
        rig.expectNothingLeftDark()
        #expect(status.state == .active)
        #expect(status.physicalOff == [lg, m34])
        #expect(rig.logText.contains("turned off 2 monitors in 0.0 s\n"))
        #expect(!rig.logText.contains("took over 5 s"))
    }

    @Test func aFailedTransactionFallsBackToOneAtATime() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.failTransactions = true }

        let status = try await rig.session.start(parsec())

        #expect(rig.logText.contains(Self.fallbackLine))
        #expect(rig.simulated.switchTransactions == ["disable \(m34)", "disable \(lg)"])
        // The same end state as a start whose transaction worked.
        rig.expectMonitorsOff()
        rig.expectNothingLeftDark()
        #expect(status.state == .active)
        #expect(status.physicalOff == [lg, m34])
        #expect(rig.simulated.topology().main?.id == status.displayID)
        #expect(try rig.ledger?.state == .active)
        #expect(!rig.logText.contains("turned off"))
    }

    @Test func theFallbackSkipsAMonitorTheTransactionTurnedOff() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.ignoreInTransactions = [lg] }

        let status = try await rig.session.start(parsec())

        #expect(rig.logText.contains("together failed (display 2 is still online 3 seconds after turning it off)"))
        #expect(rig.simulated.switchTransactions == ["disable \(m34)", "disable \(lg)"])
        #expect(rig.count("disable \(m34)") == 1, "Not switched a second time")
        rig.expectMonitorsOff()
        #expect(status.state == .active)
        #expect(try rig.ledger?.physical.map(\.id) == [lg, m34], "The ledger keeps both")
    }

    @Test func oneMonitorWhoseTransactionFailsRollsBackWithoutAFallback() async throws {
        let rig = try SessionRig()
        rig.backend.update { $0.failTransactions = true }

        await #expect(throws: SessionError(reason: "scripted failure of the transaction")) {
            try await rig.session.start(parsec(keepOn: [lgUUID]))
        }

        #expect(!rig.logText.contains("one at a time"))
        #expect(rig.countOfPrefix("disable") == 0, "No second try of the same call")
        rig.expectDeskRestored()
        #expect(try rig.ledger == nil)
    }

    @Test func theNeverZeroRefusalComesBeforeAnyChange() async throws {
        let rig = try SessionRig()
        let transactions = Recorder<[DisplayID]>()
        rig.backend.update { $0.beforeTransaction = { ids, _ in transactions.append(ids) } }
        rig.makeScreenStopCounting()

        await #expect(throws: SessionError(reason: "would leave no working display")) {
            try await rig.session.start(parsec())
        }

        #expect(transactions.values.isEmpty)
        #expect(rig.countOfPrefix("disable") == 0)
        rig.expectDeskRestored()
    }

    @Test func theLedgerRecordsEveryMonitorBeforeTheTransaction() async throws {
        let rig = try SessionRig()
        let store = rig.store
        let recorded = Recorder<[DisplayID]>()
        rig.backend.update { script in
            script.beforeTransaction = { _, _ in
                recorded.append(store.saves.last?.ledger.physical.map(\.id) ?? [])
            }
        }

        _ = try await rig.session.start(parsec())

        #expect(recorded.values == [[lg, m34]])
    }

    @Test func aSlowTransactionSaysSo() async throws {
        let rig = try SessionRig()
        let clock = rig.clock
        rig.backend.update { $0.beforeTransaction = { _, _ in clock.advance(by: 10) } }

        _ = try await rig.session.start(parsec())

        #expect(rig.logText.contains("turned off 2 monitors in 10.0 s (macOS took over 5 s to confirm)\n"))
        rig.expectMonitorsOff()
    }

    @Test func theLineTimesTheMacOSCallNotTheWaitAfterIt() async throws {
        let rig = try SessionRig()
        let clock = rig.clock
        let lgOnlineUntil = Recorder<Date>()
        rig.backend.update { script in
            script.beforeTransaction = { _, _ in
                clock.advance(by: 4.2)
                lgOnlineUntil.append(clock.now().addingTimeInterval(2))
            }
            // After the call returns, the LG keeps reading online for 2 more seconds.
            script.rewrite = { topology in
                guard let until = lgOnlineUntil.values.first, clock.now() < until else { return }
                for index in topology.displays.indices where topology.displays[index].id == lg {
                    topology.displays[index].isOnline = true
                }
            }
        }

        _ = try await rig.session.start(parsec())

        #expect(rig.logText.contains("turned off 2 monitors in 4.2 s\n"))
        rig.expectMonitorsOff()
    }

    @Test func aTransactionUnder5sDoesNotSaySo() async throws {
        let rig = try SessionRig()
        let clock = rig.clock
        rig.backend.update { $0.beforeTransaction = { _, _ in clock.advance(by: 4.2) } }

        _ = try await rig.session.start(parsec())

        #expect(rig.logText.contains("turned off 2 monitors in 4.2 s\n"))
        #expect(!rig.logText.contains("took over 5 s"))
    }

    // MARK: Enforcement

    @Test func monitorsThatCameBackGoOffInOneTransaction() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg, m34])

        await rig.session.topologyChanged()

        #expect(rig.simulated.switchTransactions == ["disable \(m34) \(lg)", "disable \(m34) \(lg)"])
        rig.expectMonitorsOff()
        rig.expectNothingLeftDark()
        #expect(rig.logText.contains("Display \(lg) came back on and was turned off again"))
        #expect(rig.logText.contains("Display \(m34) came back on and was turned off again"))
        #expect(rig.logText.components(separatedBy: "turned off 2 monitors in").count == 3, "The start's and this one")
        #expect(rig.session.status().state == .active)
    }

    @Test func oneMonitorThatCameBackGoesOffAlone() async throws {
        let rig = try await started()
        rig.simulated.simulateWake(reconnecting: [lg])

        await rig.session.topologyChanged()

        #expect(rig.simulated.switchTransactions.last == "disable \(lg)")
        #expect(rig.logText.contains("turned off 1 monitor in 0.0 s\n"))
        rig.expectMonitorsOff()
    }

    @Test func enforcementFallsBackToOneAtATime() async throws {
        let rig = try await started()
        rig.backend.update { $0.failTransactions = true }
        rig.simulated.simulateWake(reconnecting: [lg, m34])

        await rig.session.topologyChanged()

        #expect(rig.logText.contains(Self.fallbackLine))
        #expect(Array(rig.simulated.switchTransactions.dropFirst()) == ["disable \(m34)", "disable \(lg)"])
        rig.expectMonitorsOff()
        rig.expectNothingLeftDark()
        #expect(rig.logText.contains("Display \(lg) came back on and was turned off again"))
        #expect(rig.logText.contains("Display \(m34) came back on and was turned off again"))
        #expect(rig.session.status().state == .active)
    }

    @Test func enforcementFallbackSkipsAMonitorTheTransactionTurnedOff() async throws {
        let rig = try await started()
        rig.backend.update { $0.ignoreInTransactions = [lg] }
        rig.simulated.simulateWake(reconnecting: [lg, m34])

        await rig.session.topologyChanged()

        #expect(Array(rig.simulated.switchTransactions.dropFirst()) == ["disable \(m34)", "disable \(lg)"])
        rig.expectMonitorsOff()
        #expect(rig.logText.contains("Display \(lg) came back on and was turned off again"))
        #expect(rig.logText.contains("Display \(m34) came back on and was turned off again"))
    }

    @Test func oneReturnedMonitorWhoseTransactionFailsIsLoggedWithoutAFallback() async throws {
        let rig = try await started()
        rig.backend.update { $0.failTransactions = true }
        rig.simulated.simulateWake(reconnecting: [lg])
        let disables = rig.count("disable \(lg)")

        await rig.session.topologyChanged()

        #expect(rig.logText.contains("Turning display \(lg) off again failed: scripted failure of the transaction"))
        #expect(!rig.logText.contains("one at a time"))
        #expect(rig.count("disable \(lg)") == disables, "No second try of the same call")
        #expect(rig.session.status().state == .active)
    }

    // MARK: Resume

    @Test func resumeFallbackSkipsAMonitorTheTransactionTurnedOff() async throws {
        let rig = try await started()
        rig.crash()
        rig.relaunch()
        rig.simulated.simulateWake(reconnecting: [lg, m34])
        let disables = rig.count("disable \(m34)")
        rig.backend.update { $0.ignoreInTransactions = [lg] }

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.count("disable \(m34)") == disables + 1, "Not switched a second time")
        rig.expectMonitorsOff()
        #expect(rig.session.status().state == .active)
    }

    @Test func aResumeTurnsReturnedMonitorsOffInOneTransaction() async throws {
        let rig = try await started()
        rig.crash()
        rig.relaunch()
        rig.simulated.simulateWake(reconnecting: [lg, m34])

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.simulated.switchTransactions.last == "disable \(m34) \(lg)")
        rig.expectMonitorsOff()
        #expect(rig.session.status().state == .active)
    }

    @Test func aResumeFallsBackToOneAtATime() async throws {
        let rig = try await started()
        rig.crash()
        rig.relaunch()
        rig.simulated.simulateWake(reconnecting: [lg, m34])
        rig.backend.update { $0.failTransactions = true }

        await rig.session.resumeAtLaunch(safeMode: false)

        #expect(rig.logText.contains(Self.fallbackLine))
        #expect(Array(rig.simulated.switchTransactions.suffix(2)) == ["disable \(m34)", "disable \(lg)"])
        rig.expectMonitorsOff()
        #expect(rig.session.status().state == .active)
    }
}
