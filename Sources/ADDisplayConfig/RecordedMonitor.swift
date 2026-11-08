import ADModel

/// How a recorded monitor is found on the display list, online or off. The restorer, the reconnect
/// and a session's enforcement all go by this one rule, so they can't drift apart.
///
/// A listing is the monitor if it reads as physical, has the recorded vendor, model and serial, and is
/// under the recorded ID or at the recorded registry location. An ID can change hands, so the ID comes
/// first, and the location stands in for it. A listing that only shares the vendor, model and serial
/// isn't this monitor: it may be a stale twin macOS keeps on a port the monitor used before, or the
/// monitor plugged in somewhere else, which macOS turns on by itself. So a recorded monitor with
/// neither its ID nor its location listed is missing, never dark.
public enum RecordedMonitor {
    public static func listing(id: DisplayID, identity: DisplayIdentity, online: Bool, in topology: Topology) -> DisplaySnapshot? {
        let listings = topology.displays.filter { display in
            display.isOnline == online && isListing(display, id: id, identity: identity)
        }
        return listings.first { $0.id == id } ?? listings.first
    }

    public static func isListing(_ display: DisplaySnapshot, id: DisplayID, identity: DisplayIdentity) -> Bool {
        let atRecordedPort = identity.registryLocation != nil && display.identity.registryLocation == identity.registryLocation
        return display.kind == .physical
            && display.identity.vendor == identity.vendor
            && display.identity.model == identity.model
            && display.identity.serial == identity.serial
            && (display.id == id || atRecordedPort)
    }
}

extension PhysicalRecord {
    /// This monitor if it's online.
    public func onlineDisplay(in topology: Topology) -> DisplaySnapshot? {
        RecordedMonitor.listing(id: id, identity: identity, online: true, in: topology)
    }

    /// This monitor listed offline, which is what a dark monitor looks like.
    public func offlineListing(in topology: Topology) -> DisplaySnapshot? {
        RecordedMonitor.listing(id: id, identity: identity, online: false, in: topology)
    }
}
