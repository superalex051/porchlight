import ADDisplays
import ADModel
import ADSafety
import Foundation

extension CommandDispatcher {
    private static let wakeLimitSeconds = 5.0
    private static let wakePollSeconds = 0.25

    func connectedValue(of device: SelectedDevice) -> String {
        device.isOnline ? "on" : "off"
    }

    /// A monitor goes by the ID recorded before it went off, because macOS won't find it by UUID. A
    /// display that's on already is left alone.
    func turnOn(_ devices: [SelectedDevice]) async throws {
        let offline = devices.filter { !$0.isOnline }
        for device in offline where device.definition == nil && device.kind != .physical {
            throw CommandRefusal.bare
        }

        if offline.contains(where: { $0.definition == nil }) { await wakeDisplays() }
        for device in offline {
            if let definition = device.definition {
                try await connectScreen(definition)
            } else if let id = device.id {
                try await operations.connect(id)
            }
        }
    }

    /// One plan, checked as a whole. A display that's off already is left alone.
    func turnOff(_ devices: [SelectedDevice]) async throws {
        let online = devices.filter(\.isOnline)
        guard !online.isEmpty else { return }
        try refuseTurningOff(online)

        // This is how `set -connected=on` finds the monitor again, so nothing goes off without it. A
        // display that read with no UUID gets no entry, even from a write that succeeds.
        do {
            try registry.update(from: backend.topology())
        } catch {
            throw SessionError.cannotWriteState
        }
        let recorded = Set(registry.currentBootEntries().map(\.lastID))
        for device in online where device.definition == nil {
            guard let id = device.id, recorded.contains(id) else {
                throw CommandRefusal(reason: "\(device.name) can't be recorded, so it stays on")
            }
        }

        // The main display last, as a session does it.
        for device in online.filter({ !$0.isMain }) + online.filter(\.isMain) {
            if let definition = device.definition {
                try await releaseScreen(definition)
            } else if let id = device.id {
                try await operations.disconnect(id)
            }
        }
    }

    /// Whether these can go off. Only monitors and screens made with `create` can: a session's screen
    /// goes with its session, and another app's virtual display may be the very one a remote user is
    /// looking at. A `set` asks this before it changes anything else.
    func refuseTurningOff(_ devices: [SelectedDevice]) throws {
        let online = devices.filter(\.isOnline)
        guard !online.isEmpty else { return }
        for device in online where device.definition == nil && device.kind != .physical {
            throw CommandRefusal(
                reason: device.kind == .ownVirtual
                    ? "that screen belongs to a session, use session end"
                    : "\(device.name) is not a display this can turn off"
            )
        }
        try refuseIfNothingWouldRemain(disconnecting: online, in: backend.topology())
    }

    /// Our screen counts only while the guardian protects it and a recorded monitor is waiting to come
    /// back to replace it. With every monitor kept on there's nothing to come back, so the end would take
    /// the screen away and leave nothing. An end that failed partway doesn't count either, because it
    /// still has to take the screen away.
    func refuseIfNothingWouldRemain(disconnecting devices: [SelectedDevice], in topology: Topology) throws {
        let status = session.status()
        try NeverZeroRule.check(
            topology: topology,
            disconnecting: Set(devices.compactMap(\.id)),
            inProtectedSession: (status.state == .active || status.state == .degraded) && !status.physicalOff.isEmpty
        ).get()
    }

    /// With every display asleep, turning a monitor on fails after blocking about 10 seconds. Going
    /// ahead at the limit is fine, because then the failure says so.
    private func wakeDisplays() async {
        session.power.declareUserActivity()
        let deadline = clock.now().addingTimeInterval(Self.wakeLimitSeconds)
        while !backend.topology().displays.contains(where: \.isActive), clock.now() < deadline {
            do {
                try await clock.sleep(seconds: Self.wakePollSeconds)
            } catch {
                return
            }
        }
    }
}
