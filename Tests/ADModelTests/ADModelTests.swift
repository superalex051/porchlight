import ADModel
import Foundation
import Testing

// Plain `import`, not `@testable`, so these tests also prove the public surface later tasks use.

private let specUUID = "63C872E8-4E48-4D23-9889-F8EE8F82BEEE"

private let activeStatus = SessionStatus(
    state: .active,
    client: "parsec",
    displayID: 9,
    uuid: specUUID,
    looksLike: ScreenSize(w: 1728, h: 1080),
    pixels: ScreenSize(w: 3456, h: 2160),
    hiDPI: true,
    hz: 60,
    ownerPIDs: [4242, 77],
    physicalOff: [2, 4]
)

private let identity = DisplayIdentity(
    uuid: "11111111-2222-3333-4444-555555555555",
    vendor: 7789,
    model: 30000,
    serial: 12,
    alphanumericSerial: "ABC123",
    productName: "Test Panel",
    registryLocation: "IOService:/test",
    weekOfManufacture: 10,
    yearOfManufacture: 2024
)

private let mode1x = DisplayMode(
    pointsWide: 2560, pointsHigh: 1440, pixelsWide: 2560, pixelsHigh: 1440, refreshHz: 120
)

private func snapshot(
    id: DisplayID,
    uuid: String?,
    isOnline: Bool = true,
    isActive: Bool = true,
    isMain: Bool = false
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        identity: DisplayIdentity(uuid: uuid, vendor: 7789, model: 30000, serial: id),
        kind: .physical,
        isOnline: isOnline,
        isActive: isActive,
        isMain: isMain,
        isAsleep: false,
        origin: DisplayOrigin(x: -446, y: 1440),
        mode: mode1x
    )
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func sortedJSONText<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

// MARK: - ScreenSize

@Test func screenSizeParsesAndPrints() {
    let size = ScreenSize(parsing: "1728x1080")
    #expect(size == ScreenSize(w: 1728, h: 1080))
    #expect(size?.w == 1728)
    #expect(size?.h == 1080)
    #expect(size?.description == "1728x1080")
    #expect("\(ScreenSize(w: 640, h: 360))" == "640x360")
}

@Test(arguments: [
    "17x", "x10", "-1x5", "", "x", "5x-1", "+1x5", "1x+5", "1x2x3", "0x5", "5x0", "abc",
    "1728X1080", " 1728x1080", "1728x1080 ", "1728 x 1080", "17.5x10",
    "99999999999999999999x10",
])
func screenSizeRejectsGarbage(_ text: String) {
    #expect(ScreenSize(parsing: text) == nil)
}

// MARK: - DisplayMode

@Test func displayModeMatchesOnWholeHz() {
    func mode(hz: Double) -> DisplayMode {
        DisplayMode(pointsWide: 2560, pointsHigh: 1440, pixelsWide: 2560, pixelsHigh: 1440, refreshHz: hz)
    }
    #expect(mode(hz: 119.88).matches(mode(hz: 119.88)))
    #expect(!mode(hz: 120).matches(mode(hz: 144)))
    // Whole-number refresh means the nearest whole number, as `get -refreshRate` prints it.
    #expect(mode(hz: 119.88).matches(mode(hz: 120)))
    #expect(mode(hz: 59.94).matches(mode(hz: 60)))
    #expect(!mode(hz: 119.4).matches(mode(hz: 120)))
}

@Test func displayModeMatchRequiresPointsAndPixels() {
    let base = DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60)
    #expect(base.matches(base))
    for other in [
        DisplayMode(pointsWide: 1727, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60),
        DisplayMode(pointsWide: 1728, pointsHigh: 1079, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60),
        DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 1728, pixelsHigh: 2160, refreshHz: 60),
        DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 1080, refreshHz: 60),
    ] {
        #expect(!base.matches(other))
    }
}

@Test func hiDPIDerivedFromPixels() {
    let hiDPI = DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 60)
    #expect(hiDPI.isHiDPI)
    #expect(!mode1x.isHiDPI)
}

// MARK: - Session status

@Test func statusLineMatchesSpecExactly() {
    #expect(
        activeStatus.statusLine
            == "state=active client=parsec displayID=9 UUID=63C872E8-4E48-4D23-9889-F8EE8F82BEEE lookslike=1728x1080 pixels=3456x2160 hz=60 off=2,4"
    )
}

@Test func idleStatusLineIsStateIdle() {
    #expect(SessionStatus(state: .idle).statusLine == "state=idle")
    // Leftover fields on an idle status never reach the line.
    var stale = activeStatus
    stale.state = .idle
    #expect(stale.statusLine == "state=idle")
}

@Test func statusLineKeepsOffFieldWhenNothingIsOff() {
    var status = activeStatus
    status.state = .degraded
    status.physicalOff = []
    #expect(
        status.statusLine
            == "state=degraded client=parsec displayID=9 UUID=63C872E8-4E48-4D23-9889-F8EE8F82BEEE lookslike=1728x1080 pixels=3456x2160 hz=60 off="
    )
}

@Test func statusLineLeavesOutUnknownFields() {
    let status = SessionStatus(state: .starting, client: "parsec")
    #expect(status.statusLine == "state=starting client=parsec off=")
}

@Test func statusJSONIsAPIVersion1() {
    let expected: JSONValue = .object([
        "apiVersion": .number(1),
        "state": .string("active"),
        "client": .string("parsec"),
        "displayID": .number(9),
        "displayUUID": .string(specUUID),
        "looksLike": .object(["w": .number(1728), "h": .number(1080)]),
        "pixels": .object(["w": .number(3456), "h": .number(2160)]),
        "hiDPI": .bool(true),
        "hz": .number(60),
        "ownerPIDs": .array([.number(4242), .number(77)]),
        "physicalOff": .array([.number(2), .number(4)]),
    ])
    #expect(activeStatus.asJSON == expected)
    #expect(SessionAPI.version == 1)
}

@Test func idleStatusJSONIsOnlyStateAndVersion() throws {
    #expect(SessionStatus(state: .idle).asJSON == .object(["state": .string("idle"), "apiVersion": .number(1)]))
    // Leftover fields on an idle status never reach the JSON either.
    var stale = activeStatus
    stale.state = .idle
    #expect(try sortedJSONText(stale.asJSON) == #"{"apiVersion":1,"state":"idle"}"#)
}

@Test func liveStatusJSONKeepsEveryKeyWithNullForUnknown() throws {
    let starting = SessionStatus(state: .starting, client: "ipad")
    #expect(
        try sortedJSONText(starting.asJSON)
            == #"{"apiVersion":1,"client":"ipad","displayID":null,"displayUUID":null,"hiDPI":null,"hz":null,"looksLike":null,"ownerPIDs":[],"physicalOff":[],"pixels":null,"state":"starting"}"#
    )
}

@Test func statusJSONEncodesWholeNumbers() throws {
    // A capturing app reads displayID from this, so it must never print as 9.0 or in exponent form.
    var status = activeStatus
    status.displayID = 4_294_967_295
    #expect(
        try sortedJSONText(status.asJSON)
            == #"{"apiVersion":1,"client":"parsec","displayID":4294967295,"displayUUID":"63C872E8-4E48-4D23-9889-F8EE8F82BEEE","hiDPI":true,"hz":60,"looksLike":{"h":1080,"w":1728},"ownerPIDs":[4242,77],"physicalOff":[2,4],"pixels":{"h":2160,"w":3456},"state":"active"}"#
    )
}

// MARK: - Session limits

@Test func limitsAcceptBoundaries() {
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 640, h: 360), hz: 24) == nil)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 3840, h: 2400), hz: 240) == nil)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 1728, h: 1080), hz: 60) == nil)
}

@Test func limitsRejectOutside() {
    let widthReason = "lookslike width must be 640 to 3840"
    let heightReason = "lookslike height must be 360 to 2400"
    let hzReason = "hz must be 24 to 240"
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 639, h: 1080), hz: 60) == widthReason)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 3841, h: 1080), hz: 60) == widthReason)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 1728, h: 359), hz: 60) == heightReason)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 1728, h: 2401), hz: 60) == heightReason)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 1728, h: 1080), hz: 23) == hzReason)
    #expect(SessionLimits.validate(looksLike: ScreenSize(w: 1728, h: 1080), hz: 241) == hzReason)
}

// MARK: - Presets

@Test func builtInPresetsMatchSpec() {
    struct Row: Equatable {
        var name: String
        var lookslike: String
        var pixels: ScreenSize?
        var hidpi: Bool
        var hz: Int
    }
    let rows = Presets.builtIn.map {
        Row(name: $0.name, lookslike: $0.lookslike, pixels: $0.pixels, hidpi: $0.hidpi, hz: $0.hz)
    }
    #expect(
        rows == [
            Row(name: "MacBook 14", lookslike: "1728x1080", pixels: ScreenSize(w: 3456, h: 2160), hidpi: true, hz: 60),
            Row(name: "MacBook 14 120 Hz", lookslike: "1728x1080", pixels: ScreenSize(w: 3456, h: 2160), hidpi: true, hz: 120),
            Row(name: "MacBook 14 Sharpest", lookslike: "1512x945", pixels: ScreenSize(w: 3024, h: 1890), hidpi: true, hz: 60),
            Row(name: "MacBook 14 More Room", lookslike: "1920x1200", pixels: ScreenSize(w: 3840, h: 2400), hidpi: true, hz: 60),
            Row(name: "4K Screen", lookslike: "1920x1080", pixels: ScreenSize(w: 3840, h: 2160), hidpi: true, hz: 60),
            Row(name: "1440p Screen", lookslike: "2560x1440", pixels: ScreenSize(w: 2560, h: 1440), hidpi: false, hz: 60),
            Row(name: "1080p Screen", lookslike: "1920x1080", pixels: ScreenSize(w: 1920, h: 1080), hidpi: false, hz: 60),
        ]
    )
}

@Test func builtInPresetsAreWithinLimits() throws {
    for preset in Presets.builtIn {
        let size = try #require(ScreenSize(parsing: preset.lookslike))
        #expect(SessionLimits.validate(looksLike: size, hz: preset.hz) == nil)
    }
}

@Test func presetLineMatchesSpec() {
    #expect(Presets.builtIn[0].line == "MacBook 14: lookslike=1728x1080 pixels=3456x2160 hz=60")
    #expect(Presets.builtIn[1].line == "MacBook 14 120 Hz: lookslike=1728x1080 pixels=3456x2160 hz=120")
    #expect(Presets.builtIn[5].line == "1440p Screen: lookslike=2560x1440 pixels=2560x1440 hz=60")
}

@Test func presetWithBadSizeHasNoPixels() {
    let preset = Preset(name: "Broken", lookslike: "wide", hidpi: true, hz: 60)
    #expect(preset.pixels == nil)
    #expect(preset.line == "Broken: lookslike=wide pixels=? hz=60")
}

@Test func presetFileShapeIsTheFourSpecKeys() throws {
    let text = #"{"name":"iPad Air","lookslike":"1180x820","hidpi":true,"hz":60}"#
    let decoded = try JSONDecoder().decode(Preset.self, from: Data(text.utf8))
    #expect(decoded == Preset(name: "iPad Air", lookslike: "1180x820", hidpi: true, hz: 60))
    #expect(decoded.pixels == ScreenSize(w: 2360, h: 1640))
    #expect(try sortedJSONText(decoded) == #"{"hidpi":true,"hz":60,"lookslike":"1180x820","name":"iPad Air"}"#)
}

// MARK: - Feature registry

private let specKeys = [
    // Features
    "connected", "main", "placement", "resolution", "refreshRate", "hiDPI", "identifiers",
    "create", "discard", "virtualScreenName", "useResolutionList", "resolutionList",
    "virtualScreenHiDPI",
    // Selectors
    "UUID", "displayID", "name", "nameLike", "originalName", "tagID", "type",
    "displayWithMainStatus",
    // Extension keys
    "launchAtLogin", "spiReport", "pinRefreshRate",
    // Session parameters, except hidpi, which is hiDPI (see sessionHidpiSharesHiDPIEntry)
    "client", "lookslike", "hz", "preset", "ownerpid", "keepon", "force", "reason",
    // Dry run
    "dryRunPlan",
]

@Test func registryListsEverySpecKey() {
    for key in specKeys {
        #expect(FeatureRegistry.canonical(key) == key)
    }
    #expect(Set(FeatureRegistry.all.map(\.key)) == Set(specKeys))
}

@Test func registryIsCaseInsensitive() {
    #expect(FeatureRegistry.canonical("MAIN") == "main")
    #expect(FeatureRegistry.canonical("uuid") == "UUID")
    #expect(FeatureRegistry.canonical("REFRESHRATE") == "refreshRate")
    #expect(FeatureRegistry.canonical("LooksLike") == "lookslike")
    #expect(FeatureRegistry.canonical("N") == "nameLike")
    #expect(FeatureRegistry.canonical("DEVICETYPE") == "type")
}

@Test func aliasNMapsToNameLike() {
    #expect(FeatureRegistry.canonical("n") == "nameLike")
}

@Test func aliasDeviceTypeMapsToType() {
    #expect(FeatureRegistry.canonical("deviceType") == "type")
}

@Test func unknownFeatureIsNil() {
    #expect(FeatureRegistry.canonical("nonexistentFeatureXYZ") == nil)
    #expect(FeatureRegistry.canonical("") == nil)
}

@Test func sessionHidpiSharesHiDPIEntry() {
    // Names are case-insensitive, so the session parameter and the feature are one key.
    #expect(FeatureRegistry.canonical("hidpi") == "hiDPI")
    #expect(FeatureRegistry.canonical("hiDPI") == "hiDPI")
}

@Test func registryNamesNeverCollide() {
    var seen: Set<String> = []
    for feature in FeatureRegistry.all {
        for name in [feature.key] + feature.aliases {
            #expect(seen.insert(name.lowercased()).inserted, "\(name) is listed twice")
        }
    }
}

@Test func outputStylesMatchObservedOutput() throws {
    func style(_ key: String) throws -> OutputStyle {
        try #require(FeatureRegistry.all.first { $0.key == key }).style
    }
    #expect(try style("connected") == .onOff)
    #expect(try style("hiDPI") == .onOff)
    #expect(try style("main") == .trueFalse)
    #expect(try style("resolution") == .value)
    #expect(try style("refreshRate") == .value)
    #expect(try style("placement") == .value)
    #expect(try style("pinRefreshRate") == .value)
}

// MARK: - Topology

@Test func topologyLookupsWork() {
    let topology = Topology(displays: [
        snapshot(id: 2, uuid: "AAAAAAAA-0000-0000-0000-000000000002", isMain: true),
        snapshot(id: 4, uuid: "BBBBBBBB-0000-0000-0000-000000000004"),
        snapshot(id: 5, uuid: nil, isOnline: false, isActive: false),
    ])
    #expect(topology.display(2)?.id == 2)
    #expect(topology.display(99) == nil)
    #expect(topology.display(uuid: "BBBBBBBB-0000-0000-0000-000000000004")?.id == 4)
    #expect(topology.display(uuid: "bbbbbbbb-0000-0000-0000-000000000004")?.id == 4)
    #expect(topology.display(uuid: "CCCCCCCC-0000-0000-0000-000000000000") == nil)
    #expect(topology.online.map(\.id) == [2, 4])
    #expect(topology.onlineIDs == [2, 4])
    #expect(topology.main?.id == 2)
}

@Test func topologyWithNoDisplaysIsEmpty() {
    let topology = Topology(displays: [])
    #expect(topology.online.isEmpty)
    #expect(topology.onlineIDs.isEmpty)
    #expect(topology.main == nil)
    #expect(topology.display(1) == nil)
    #expect(topology.display(uuid: "x") == nil)
}

// MARK: - Commands

@Test func commandResultHelpers() {
    #expect(
        CommandResult.success("on")
            == CommandResult(ok: true, payload: "on", reason: nil, warning: nil, json: nil)
    )
    #expect(
        CommandResult.success("state=idle", json: .bool(true), warning: "careful")
            == CommandResult(ok: true, payload: "state=idle", reason: nil, warning: "careful", json: .bool(true))
    )
    #expect(CommandResult.success() == CommandResult(ok: true))
    #expect(
        CommandResult.failure("would leave no working display")
            == CommandResult(ok: false, reason: "would leave no working display")
    )
    #expect(CommandResult.failure() == CommandResult(ok: false))
}

// MARK: - JSONValue

@Test func jsonValueDecodesEachKind() throws {
    let text = #"{"a":"x","b":1,"c":true,"d":[1,"y",false,null,{}],"e":null,"f":1.5}"#
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(
        decoded
            == .object([
                "a": .string("x"),
                "b": .number(1),
                "c": .bool(true),
                "d": .array([.number(1), .string("y"), .bool(false), .null, .object([:])]),
                "e": .null,
                "f": .number(1.5),
            ])
    )
    #expect(try roundTrip(decoded) == decoded)
}

// MARK: - Codable

@Test func codableRoundTrips() throws {
    let size = ScreenSize(w: 1728, h: 1080)
    #expect(try roundTrip(size) == size)

    let origin = DisplayOrigin(x: -446, y: 1440)
    #expect(try roundTrip(origin) == origin)

    let hiDPIMode = DisplayMode(pointsWide: 1728, pointsHigh: 1080, pixelsWide: 3456, pixelsHigh: 2160, refreshHz: 119.88)
    #expect(try roundTrip(hiDPIMode) == hiDPIMode)
    #expect(try roundTrip(hiDPIMode).isHiDPI)

    #expect(try roundTrip(identity) == identity)
    let bare = DisplayIdentity(vendor: 0, model: 0, serial: 0)
    #expect(try roundTrip(bare) == bare)

    let topology = Topology(displays: [
        snapshot(id: 2, uuid: "AAAAAAAA-0000-0000-0000-000000000002", isMain: true),
        snapshot(id: 5, uuid: nil, isOnline: false, isActive: false),
    ])
    #expect(try roundTrip(topology) == topology)

    let request = CommandRequest(
        operations: ["session", "start"],
        parameters: [
            CommandParameter(name: "client", value: "parsec"),
            CommandParameter(name: "force", value: nil),
        ]
    )
    #expect(try roundTrip(request) == request)

    let result = CommandResult.success("state=idle", json: activeStatus.asJSON, warning: "w")
    #expect(try roundTrip(result) == result)
    #expect(try roundTrip(CommandResult.failure("why")) == .failure("why"))

    #expect(try roundTrip(activeStatus) == activeStatus)
    #expect(try roundTrip(SessionStatus(state: .idle)) == SessionStatus(state: .idle))

    let sessionRequest = SessionRequest(
        client: "parsec",
        looksLike: size,
        hiDPI: true,
        hz: 60,
        ownerPIDs: [123, 456],
        keepOn: ["AAAAAAAA-0000-0000-0000-000000000002"]
    )
    let decodedRequest = try roundTrip(sessionRequest)
    #expect(decodedRequest.client == "parsec")
    #expect(decodedRequest.looksLike == size)
    #expect(decodedRequest.hiDPI)
    #expect(decodedRequest.hz == 60)
    #expect(decodedRequest.ownerPIDs == [123, 456])
    #expect(decodedRequest.keepOn == ["AAAAAAAA-0000-0000-0000-000000000002"])

    for preset in Presets.builtIn {
        #expect(try roundTrip(preset) == preset)
    }

    let record = PhysicalRecord(id: 2, identity: identity, origin: origin, mode: mode1x, wasMain: true)
    #expect(try roundTrip(record) == record)

    let entry = RegistryEntry(
        identity: identity,
        lastID: 2,
        bootSessionID: "boot-1",
        tagID: 1,
        kind: .physical,
        pinnedRefreshHz: 120
    )
    #expect(try roundTrip(entry) == entry)

    for kind in [DisplayKind.physical, .ownVirtual, .parsecVirtual, .osFallback, .otherVirtual, .emptyPipe] {
        #expect(try roundTrip(kind) == kind)
    }
    for state in [SessionState.idle, .starting, .active, .degraded, .ending] {
        #expect(try roundTrip(state) == state)
    }
}
