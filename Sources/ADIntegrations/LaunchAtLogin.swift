import ServiceManagement

public protocol LaunchAtLoginControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ on: Bool) throws
}

/// Opens the installed app at login. Only call this from the copy in `/Applications`, because the
/// registration belongs to the app bundle and its signature. Tests must not call it.
public struct SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}

    /// False while the login item waits for approval in System Settings, because it won't open yet.
    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Asking for the state it's already in does nothing, because `SMAppService` reports that as an
    /// error. Turning it off checks for `.notRegistered` rather than `isEnabled`, so a login item
    /// waiting for approval still gets removed.
    public func setEnabled(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
