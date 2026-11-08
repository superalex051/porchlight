import ADModel

/// The rules from the spec's display kinds table.
public enum DisplayClassifier {
    public static let ownVendor: UInt32 = 0xF0F0
    public static let ownProduct: UInt32 = 0xAD01

    /// "unkn" and "virt", the identity of the display macOS creates when no other is left.
    private static let fallbackVendor: UInt32 = 0x756E_6B6E
    private static let fallbackModel: UInt32 = 0x7669_7274

    /// What every read of a display ID returns once the ID has gone away.
    private static let vanishedVendor: UInt32 = 0xFFFF_FFFF

    private static let parsecName = "Parsec Virtual Display"

    public static func kind(isVirtual: Bool, vendor: UInt32, model: UInt32, name: String?) -> DisplayKind {
        // Empty pipes read as not virtual, so vendor 0 only means that here. A virtual device with
        // no vendor still draws, which makes it `otherVirtual`. Neither counts as working.
        //
        // A display that has just gone away also reads as not virtual, because its info dictionary
        // is null, and its vendor isn't 0. Calling it physical could let the never-zero check count
        // it, and approve turning off the real last monitor.
        guard isVirtual else { return vendor == 0 || vendor == vanishedVendor ? .emptyPipe : .physical }
        if vendor == ownVendor && model == ownProduct { return .ownVirtual }
        if name == parsecName { return .parsecVirtual }
        if vendor == fallbackVendor && model == fallbackModel { return .osFallback }
        return .otherVirtual
    }

    /// macOS can keep a record of a monitor on a port the monitor used earlier: offline, under an ID of
    /// its own, with the monitor's vendor, model and serial, and no mode or UUID. It never comes online.
    /// While a monitor with that identity is online, such a record is its stale twin and reads as an
    /// empty pipe, so nothing lists it, enables it or counts it. With no such monitor online it stays
    /// physical, because then it may be the monitor itself, plugged into another port.
    public static func markingStaleTwins(_ displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        let online = displays.filter { $0.isOnline && $0.kind == .physical }
        return displays.map { display in
            let isStaleTwin = !display.isOnline && display.kind == .physical && display.mode == nil
                && online.contains { monitor in
                    monitor.identity.vendor == display.identity.vendor
                        && monitor.identity.model == display.identity.model
                        && monitor.identity.serial == display.identity.serial
                }
            guard isStaleTwin else { return display }
            var twin = display
            twin.kind = .emptyPipe
            return twin
        }
    }
}
