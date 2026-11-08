extension CommandDispatcher {
    var launchAtLoginValue: String {
        launchAtLogin.isEnabled ? "on" : "off"
    }

    func setLaunchAtLogin(_ on: Bool) throws {
        do {
            try launchAtLogin.setEnabled(on)
        } catch {
            throw CommandRefusal(reason: "launch at login: \(error.localizedDescription)")
        }
    }
}
