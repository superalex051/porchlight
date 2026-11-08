extension CommandDispatcher {
    func mainValue(of device: SelectedDevice) -> String {
        device.isMain ? "true" : "false"
    }

    /// Only one display can be main, so this needs exactly one.
    func setMain(_ devices: [SelectedDevice]) async throws {
        guard devices.count == 1, let id = devices[0].id else { throw CommandRefusal.bare }
        try await operations.setMain(id)
    }
}
