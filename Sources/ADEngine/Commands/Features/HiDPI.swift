extension CommandDispatcher {
    /// `set -hiDPI` goes with the other mode keys, in `setMode`.
    func hiDPIValue(of device: SelectedDevice) -> String? {
        device.mode.map { $0.isHiDPI ? "on" : "off" }
    }
}
