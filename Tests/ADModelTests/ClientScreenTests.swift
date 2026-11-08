import ADModel
import Testing

private func screen(
    _ w: Int,
    _ h: Int,
    clearOfNotch: Bool = true,
    room: RoomFactor = .phoneDefault
) throws(ClientScreen.Unmatched) -> ClientScreen {
    try ClientScreen(reported: ScreenSize(w: w, h: h), clearOfNotch: clearOfNotch, phoneRoom: room)
}

private func reason(_ w: Int, _ h: Int, clearOfNotch: Bool = true, room: RoomFactor = .phoneDefault) -> String? {
    do {
        _ = try screen(w, h, clearOfNotch: clearOfNotch, room: room)
        return nil
    } catch {
        return error.reason
    }
}

/// The session screen for the size a client reported: landscape, clear of a phone's notch, a phone's
/// extra room, HiDPI at half, and the limits.
@Suite struct ClientScreenTests {
    /// iPhone 16 Pro and 17 Pro, either way up: trimmed to 2250x1206, then 4/3 of that.
    @Test(arguments: [(2622, 1206), (1206, 2622)])
    func anIPhoneProEitherWayUp(_ w: Int, _ h: Int) throws {
        let matched = try screen(w, h)

        #expect(matched.reported == ScreenSize(w: w, h: h))
        #expect(matched.looksLike == ScreenSize(w: 1500, h: 804))
        #expect(matched.pixels == ScreenSize(w: 3000, h: 1608))
        #expect(matched.isClearOfNotch)
        #expect(matched.room == .phoneDefault)
        #expect(matched.note == "clear of the notch, phone room 4/3")
    }

    @Test func anIPhoneProPixelForPixel() throws {
        let matched = try screen(2622, 1206, room: .pixelForPixel)

        #expect(matched.pixels == ScreenSize(w: 2250, h: 1206))
        #expect(matched.looksLike == ScreenSize(w: 1125, h: 603))
        #expect(matched.room == nil)
        #expect(matched.note == "clear of the notch")
    }

    @Test func anIPhoneProWithTheNotchInTheWay() throws {
        #expect(try screen(2622, 1206, clearOfNotch: false, room: .pixelForPixel).looksLike == ScreenSize(w: 1311, h: 603))
        #expect(try screen(2622, 1206, clearOfNotch: false, room: .pixelForPixel).note == nil)
        // 3496x1608 pixels.
        #expect(try screen(2622, 1206, clearOfNotch: false).looksLike == ScreenSize(w: 1748, h: 804))
        #expect(try screen(2622, 1206, clearOfNotch: false).note == "phone room 4/3")
    }

    /// 2868x1320 trims to 2464x1320 exactly, and 4/3 of 2464 is 3285.3, rounded down to 3284.
    @Test func anIPhoneProMax() throws {
        #expect(try screen(2868, 1320).looksLike == ScreenSize(w: 1642, h: 880))
        #expect(try screen(1320, 2868).looksLike == ScreenSize(w: 1642, h: 880))
        #expect(try screen(2868, 1320, room: .pixelForPixel).looksLike == ScreenSize(w: 1232, h: 660))
    }

    /// Not phones, so neither trimmed nor given room, whatever the settings.
    @Test(arguments: [(2360, 1640, 1180, 820), (1640, 2360, 1180, 820), (3024, 1964, 1512, 982), (2400, 1200, 1200, 600)])
    func aTabletOrALaptopIsPixelForPixel(_ w: Int, _ h: Int, _ lookW: Int, _ lookH: Int) throws {
        for clearOfNotch in [true, false] {
            let matched = try screen(w, h, clearOfNotch: clearOfNotch)
            #expect(matched.looksLike == ScreenSize(w: lookW, h: lookH))
            #expect(!matched.isClearOfNotch)
            #expect(matched.room == nil)
            #expect(matched.note == nil)
        }
    }

    /// An odd side rounds down: an iPhone 15 Pro's 2556x1179 trims to 2200, then 4/3 gives 2932x1572.
    @Test func oddSidesRoundDownToEvenPixels() throws {
        #expect(try screen(2556, 1179, room: .pixelForPixel).pixels == ScreenSize(w: 2200, h: 1178))
        #expect(try screen(2556, 1179).pixels == ScreenSize(w: 2932, h: 1572))
        #expect(try screen(2001, 1001).pixels == ScreenSize(w: 2000, h: 1000))
    }

    @Test func tooSmall() {
        #expect(reason(1136, 640) == "smaller than 1280x720")
        #expect(reason(640, 1136) == "smaller than 1280x720")
        #expect(reason(1278, 720) == "smaller than 1280x720")
        #expect(reason(1280, 718) == "smaller than 1280x720")
        #expect(reason(1280, 720) == nil)
    }

    /// Parsec streams up to 2160 lines, before and after a phone's room.
    @Test func tooTall() {
        #expect(reason(5120, 2880) == "taller than the 2160 lines Parsec streams")
        #expect(reason(2880, 5120) == "taller than the 2160 lines Parsec streams")
        #expect(reason(3840, 2162) == "taller than the 2160 lines Parsec streams")
        #expect(reason(3840, 2160) == nil)
        // A phone 1700 tall trims to 3172x1700 and becomes 4228x2266 with its room.
        #expect(reason(4400, 1700) == "with phone room 4/3, taller than the 2160 lines Parsec streams")
        #expect(reason(4400, 1700, room: .pixelForPixel) == nil)
    }

    @Test func tooWide() {
        #expect(reason(16_000, 2000, clearOfNotch: false, room: .pixelForPixel) == "wider than 7680")
        // 7000x1500 becomes 9332x2000 with its room.
        #expect(reason(7000, 1500, clearOfNotch: false) == "with phone room 4/3, wider than 7680")
        #expect(reason(7680, 2000, clearOfNotch: false, room: .pixelForPixel) == nil)
    }

    /// A hand-edited size can't overflow the arithmetic.
    @Test func hugeSidesAreRefusedNotOverflowed() {
        #expect(reason(Int.max, 1000) == nil, "a phone trimmed from its height")
        #expect(reason(Int.max, 1000, clearOfNotch: false) == "wider than 7680")
        #expect(reason(Int.max, Int.max) == "taller than the 2160 lines Parsec streams")
    }
}

@Suite struct RoomFactorTests {
    @Test(arguments: [("4/3", 4, 3), ("1/1", 1, 1), ("1", 1, 1), ("2", 2, 1), ("2/1", 2, 1), ("3/2", 3, 2), ("99/50", 99, 50), ("2/2", 2, 2)])
    func factorsFromOneToTwo(_ text: String, _ numerator: Int, _ denominator: Int) throws {
        let factor = try #require(RoomFactor(parsing: text))

        #expect(factor.numerator == numerator)
        #expect(factor.denominator == denominator)
    }

    @Test(arguments: ["1/2", "5/2", "0/1", "4/0", "0", "3", "", "/", "4/", "/3", "4/3/2", "+4/3", "4.0/3", " 4/3", "4 /3",
                      "100/99", "4:3", "four/three", "1.5"])
    func anythingElseIsRefused(_ text: String) {
        #expect(RoomFactor(parsing: text) == nil)
    }

    @Test func itIsWrittenAsTyped() throws {
        #expect(RoomFactor.phoneDefault.description == "4/3")
        #expect(RoomFactor.pixelForPixel.description == "1/1")
        #expect(try #require(RoomFactor(parsing: "2")).description == "2/1")
        #expect(try #require(RoomFactor(parsing: "2/2")).isPixelForPixel)
        #expect(!RoomFactor.phoneDefault.isPixelForPixel)
    }
}

/// `clients.json` with the client size settings, as the file has them.
@Suite struct ClientMappingSettingsTests {
    @Test func defaultsAreOnWithFourThirdsRoom() {
        #expect(ClientMapping.empty == ClientMapping(
            autoSize: false, clients: [], matchClient: true, clearOfNotch: true, phoneRoom: .phoneDefault
        ))
        #expect(!ClientMapping.off.autoSize && !ClientMapping.off.matchClient && !ClientMapping.off.clearOfNotch)
    }
}
