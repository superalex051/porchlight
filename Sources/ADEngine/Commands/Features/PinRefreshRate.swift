import ADModel

/// `-pinRefreshRate=120` or `-pinRefreshRate=off`.
struct PinRequest {
    /// Nil clears the pin.
    var hz: Int?

    init?(parsing text: String) {
        if text.lowercased() == "off" {
            hz = nil
            return
        }
        guard let rate = CommandValues.hz(text) else { return nil }
        hz = rate
    }
}

extension CommandDispatcher {
    func pinValue(of device: SelectedDevice) -> String {
        device.pinnedRefreshHz.map { "\($0)Hz" } ?? "off"
    }

    /// Only stores the rate. A pin never changes a display by itself. It takes effect when a session
    /// records the mode to restore. A pin is for a monitor, since nothing else gets restored.
    func setPin(_ request: PinRequest, on devices: [SelectedDevice]) throws {
        for device in devices {
            guard device.kind == .physical, let uuid = device.identity.uuid else { throw CommandRefusal.bare }
            do {
                try registry.pin(uuid: uuid, hz: request.hz)
            } catch {
                throw SessionError.cannotWriteState
            }
        }
    }
}
