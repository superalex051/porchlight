import ADDisplays
import ADModel
import Testing

private let lgVendor: UInt32 = 7789
private let lgModel: UInt32 = 23423
private let unkn: UInt32 = 0x756E_6B6E
private let virt: UInt32 = 0x7669_7274

@Test func physicalWhenNotVirtual() {
    let kind = DisplayClassifier.kind(isVirtual: false, vendor: lgVendor, model: lgModel, name: "27GL850")
    #expect(kind == .physical)
}

@Test func ownVirtualByVendorAndProduct() {
    #expect(DisplayClassifier.ownVendor == 0xF0F0)
    #expect(DisplayClassifier.ownProduct == 0xAD01)
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: 0xF0F0, model: 0xAD01, name: "Porch Light (Parsec)") == .ownVirtual)
    // The spike's throwaway screen used the same vendor with another product. It isn't ours.
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: 0xF0F0, model: 0x1512, name: "AD Spike Screen") == .otherVirtual)
}

@Test func parsecByName() {
    let kind = DisplayClassifier.kind(isVirtual: true, vendor: 0x1234, model: 0x5678, name: "Parsec Virtual Display")
    #expect(kind == .parsecVirtual)
    // The name only counts on a virtual device.
    let physical = DisplayClassifier.kind(isVirtual: false, vendor: 0x1234, model: 0x5678, name: "Parsec Virtual Display")
    #expect(physical == .physical)
}

@Test func osFallbackByVendorModel() {
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: unkn, model: virt, name: nil) == .osFallback)
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: unkn, model: 1, name: nil) == .otherVirtual)
}

@Test func otherVirtual() {
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: 0x1234, model: 0x5678, name: "Some Other Tool") == .otherVirtual)
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: 0x1234, model: 0x5678, name: nil) == .otherVirtual)
    // A virtual device can leave its vendor unset. It still draws, so it isn't an empty pipe.
    #expect(DisplayClassifier.kind(isVirtual: true, vendor: 0, model: 0, name: nil) == .otherVirtual)
}

@Test func vendorZeroIsEmptyPipe() {
    #expect(DisplayClassifier.kind(isVirtual: false, vendor: 0, model: 0, name: nil) == .emptyPipe)
}

@Test func vanishedDisplayIsNotPhysical() {
    // A display that has just gone away: every field reads all ones, and its info dictionary is null,
    // so it reads as not virtual. As physical, it could pass the never-zero check.
    let kind = DisplayClassifier.kind(isVirtual: false, vendor: 0xFFFF_FFFF, model: 0xFFFF_FFFF, name: nil)
    #expect(kind == .emptyPipe)
    // A screen just created reads the same way, but as virtual, in the spike's owner log.
    let created = DisplayClassifier.kind(isVirtual: true, vendor: 0xFFFF_FFFF, model: 0xFFFF_FFFF, name: "AD Spike Screen")
    #expect(created == .otherVirtual)
}

// MARK: Stale twins

private let m34Vendor: UInt32 = 7252
private let m34Model: UInt32 = 13314
private let m34Serial: UInt32 = 332
private let m34Mode = DisplayMode(pointsWide: 3440, pointsHigh: 1440, pixelsWide: 3440, pixelsHigh: 1440, refreshHz: 144)

private func monitor(
    _ id: DisplayID,
    serial: UInt32 = m34Serial,
    kind: DisplayKind = .physical,
    online: Bool,
    mode: DisplayMode? = nil
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        identity: DisplayIdentity(vendor: m34Vendor, model: m34Model, serial: serial),
        kind: kind,
        isOnline: online,
        isActive: online,
        isMain: false,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: mode
    )
}

/// The real Mac on 2026-11-07: the M34WQ online as 5, and ID 4 still holding its vendor, model and
/// serial on the port it used earlier that day, with no mode and no UUID.
@Test func anOfflineRecordWithAnOnlineMonitorsIdentityIsAStaleTwin() {
    let lg = DisplaySnapshot(
        id: 2,
        identity: DisplayIdentity(vendor: lgVendor, model: lgModel, serial: 198_499),
        kind: .physical,
        isOnline: true,
        isActive: true,
        isMain: true,
        isAsleep: false,
        origin: DisplayOrigin(x: 0, y: 0),
        mode: DisplayMode(pointsWide: 2560, pointsHigh: 1440, pixelsWide: 2560, pixelsHigh: 1440, refreshHz: 120)
    )
    let read = [lg, monitor(5, online: true, mode: m34Mode), monitor(4, online: false)]

    let marked = DisplayClassifier.markingStaleTwins(read)

    #expect(marked.map(\.kind) == [.physical, .physical, .emptyPipe])
    #expect(marked.map(\.id) == [2, 5, 4], "The order stays as read")
    #expect(marked[2].identity == read[2].identity, "Only the kind changes")
}

/// With the monitor itself off, the record may be that monitor, plugged into another port.
@Test func anOfflineRecordStaysPhysicalWhileNoTwinIsOnline() {
    let read = [monitor(5, online: false), monitor(4, online: false)]
    #expect(DisplayClassifier.markingStaleTwins(read).map(\.kind) == [.physical, .physical])
    #expect(DisplayClassifier.markingStaleTwins([monitor(4, online: false)]).map(\.kind) == [.physical])
}

@Test func onlyAnOfflinePhysicalRecordWithNoModeAndTheSameIdentityIsAStaleTwin() {
    let online = monitor(5, online: true, mode: m34Mode)
    let anotherSerial = monitor(4, serial: m34Serial + 1, online: false)
    let withAMode = monitor(6, online: false, mode: m34Mode)
    let virtual = monitor(7, kind: .otherVirtual, online: false)
    #expect(
        DisplayClassifier.markingStaleTwins([online, anotherSerial, withAMode, virtual]).map(\.kind)
            == [.physical, .physical, .physical, .otherVirtual]
    )

    // Only a monitor online makes a twin stale. A virtual display with the same identity doesn't.
    let virtualOnline = monitor(8, kind: .otherVirtual, online: true, mode: m34Mode)
    #expect(
        DisplayClassifier.markingStaleTwins([virtualOnline, monitor(9, online: false)]).map(\.kind)
            == [.otherVirtual, .physical]
    )
}
