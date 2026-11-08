import ADModel

extension DisplayOrigin {
    /// The `-446x1440` form.
    init?(placement text: String) {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int32(parts[0]), let y = Int32(parts[1]) else { return nil }
        self.init(x: x, y: y)
    }

    var placementText: String { "\(x)x\(y)" }
}

extension CommandDispatcher {
    func placementValue(of device: SelectedDevice) -> String? {
        guard device.isOnline else { return nil }
        return device.display?.origin.placementText
    }

    /// Two displays can't share an origin, so this needs exactly one. macOS can move a display from
    /// where it was asked to go, and this returns the words for that.
    func setPlacement(_ origin: DisplayOrigin, on devices: [SelectedDevice]) async throws -> String? {
        guard devices.count == 1, let id = devices[0].id else { throw CommandRefusal.bare }
        let placed = try await operations.setPlacement(id, origin)
        return placed == origin ? nil : "display \(id) was placed at \(placed.placementText)"
    }
}
