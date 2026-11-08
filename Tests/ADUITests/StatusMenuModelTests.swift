import ADModel
import Testing

@testable import ADUI

private let idle = SessionStatus(state: .idle)

private func session(
    _ state: SessionState = .active,
    looksLike: ScreenSize = ScreenSize(w: 1728, h: 1080),
    pixels: ScreenSize = ScreenSize(w: 3456, h: 2160),
    hz: Int = 60
) -> SessionStatus {
    SessionStatus(
        state: state,
        client: "parsec",
        displayID: 9,
        uuid: "63C872E8-4E48-4D23-9889-F8EE8F82BEEE",
        looksLike: looksLike,
        pixels: pixels,
        hz: hz,
        physicalOff: [2, 4]
    )
}

private func build(
    _ status: SessionStatus,
    presets: [Preset] = Presets.builtIn,
    safeMode: Bool = false,
    launchAtLogin: Bool = false,
    dryRun: Bool = false
) -> [StatusMenuItem] {
    StatusMenuModel.build(
        status: status,
        presets: presets,
        safeMode: safeMode,
        launchAtLogin: launchAtLogin,
        dryRun: dryRun
    )
}

private func item(_ title: String, in items: [StatusMenuItem]) throws -> StatusMenuItem {
    try #require(items.first { $0.title == title })
}

private func allTitles(_ items: [StatusMenuItem]) -> [String] {
    items.flatMap { [$0.title] + allTitles($0.children) }
}

/// The menu as it reads, top to bottom, with a separator as `-`.
private func layout(_ items: [StatusMenuItem]) -> [String] {
    items.map { $0.isSeparator ? "-" : $0.title }
}

@Suite struct StatusMenuModelTests {
    @Test func idleHasNoResolutionSubmenu() throws {
        let items = build(idle)

        #expect(items.first?.title == "No session")
        #expect(items.first?.isEnabled == false)
        #expect(items.first?.action == nil)
        #expect(!items.map(\.title).contains("Resolution"))
        #expect(try item("End Session", in: items).isEnabled == false, "With nothing to end, it can't be chosen")
    }

    @Test func activeShowsStateLine() throws {
        let items = build(session())

        #expect(items.first?.title == "Session: parsec, 1728x1080")
        #expect(items.first?.isEnabled == false)
        #expect(try item("End Session", in: items).isEnabled == true)
    }

    /// A session on its way up or down has no size to change yet, and its line says which it is.
    @Test(arguments: [SessionState.starting, .ending])
    func startingAndEndingOfferNoSize(state: SessionState) {
        let items = build(session(state))

        #expect(items.first?.title == "Session: parsec, 1728x1080 (\(state.rawValue))")
        #expect(!items.map(\.title).contains("Resolution"))
        #expect(!items.map(\.title).contains("Refresh Rate"))
    }

    /// A resize still works here, and a remote user in trouble may need it. The second line says what
    /// degraded means, and where to read why.
    @Test func degradedStillOffersSizes() throws {
        let items = build(session(.degraded))

        #expect(Array(layout(items).prefix(3)) == [
            "Session: parsec, 1728x1080 (degraded)",
            "Stopped holding the layout, see session.log",
            "-",
        ])
        #expect(items[1].isEnabled == false && items[1].action == nil)
        let resolution = try item("Resolution", in: items)
        #expect(resolution.children.filter(\.isChecked).map(\.title) == ["MacBook 14 (1728x1080)"])
        let rate = try item("Refresh Rate", in: items)
        #expect(rate.children.filter(\.isChecked).map(\.title) == ["60 Hz"])
    }

    @Test(arguments: [SessionState.idle, .starting, .active, .ending])
    func onlyDegradedExplainsItself(state: SessionState) {
        #expect(!allTitles(build(session(state))).contains { $0.hasPrefix("Stopped holding") })
    }

    @Test func resolutionSubmenuChecksCurrent() throws {
        let resolution = try item("Resolution", in: build(session()))

        #expect(resolution.action == nil)
        #expect(resolution.isEnabled)
        #expect(resolution.children.map(\.title) == [
            "MacBook 14 (1728x1080)",
            "MacBook 14 120 Hz (1728x1080)",
            "MacBook 14 Sharpest (1512x945)",
            "MacBook 14 More Room (1920x1200)",
            "4K Screen (1920x1080)",
            "1440p Screen (2560x1440, 1x)",
            "1080p Screen (1920x1080, 1x)",
        ])
        #expect(resolution.children.filter(\.isChecked).map(\.title) == ["MacBook 14 (1728x1080)"])
        #expect(resolution.children.allSatisfy { $0.isEnabled })
        #expect(resolution.children.first?.action == .selectPreset("MacBook 14"))
    }

    /// Two saved sizes can look alike and differ in pixels: 4K Screen is 1920x1080 at 2x, 1080p Screen at
    /// 1x. The check goes to the right one, and the titles tell them apart.
    @Test func sameLooksLikeIsToldApartByPixels() throws {
        let oneX = session(looksLike: ScreenSize(w: 1920, h: 1080), pixels: ScreenSize(w: 1920, h: 1080))

        let resolution = try item("Resolution", in: build(oneX))

        #expect(resolution.children.filter(\.isChecked).map(\.title) == ["1080p Screen (1920x1080, 1x)"])
        let titles = resolution.children.map(\.title)
        #expect(Set(titles).count == titles.count, "No two saved sizes read the same")
    }

    /// A preset edited by hand to another rate says so, and the action still names it exactly.
    @Test func presetAtAnotherRateShowsTheRate() throws {
        let presets = [
            Preset(name: "Fast", lookslike: "1728x1080", hidpi: true, hz: 120),
            Preset(name: "Fast Flat", lookslike: "1920x1080", hidpi: false, hz: 144),
        ]

        let children = try item("Resolution", in: build(session(hz: 120), presets: presets)).children

        #expect(children.map(\.title) == ["Fast (1728x1080, 120 Hz)", "Fast Flat (1920x1080, 1x, 144 Hz)"])
        #expect(children.map(\.isChecked) == [true, false])
        #expect(children.map(\.action) == [.selectPreset("Fast"), .selectPreset("Fast Flat")])
    }

    @Test func customSizeShownCheckedAndDisabled() throws {
        let custom = session(looksLike: ScreenSize(w: 1600, h: 900), pixels: ScreenSize(w: 3200, h: 1800))

        let children = try item("Resolution", in: build(custom)).children

        let last = try #require(children.last)
        #expect(children.count == Presets.builtIn.count + 1)
        #expect(last.title == "1600x900 (3200x1800 pixels, 60 Hz)")
        #expect(last.isChecked)
        #expect(!last.isEnabled)
        #expect(last.action == StatusMenuAction.none)
        #expect(children.dropLast().allSatisfy { !$0.isChecked })
    }

    /// A saved size at another refresh rate isn't the current one, or the menu would hide what's running.
    @Test func otherRefreshRateIsACustomSize() throws {
        let children = try item("Resolution", in: build(session(hz: 90))).children

        #expect(children.filter(\.isChecked).map(\.title) == ["1728x1080 (3456x2160 pixels, 90 Hz)"])
    }

    /// The same size at 120 Hz is the MacBook's 120 Hz preset, and at 60 Hz the plain one.
    @Test func theCheckFollowsTheRateBetweenTheMacBookPresets() throws {
        let at120 = try item("Resolution", in: build(session(hz: 120))).children
        let at60 = try item("Resolution", in: build(session(hz: 60))).children

        #expect(at120.filter(\.isChecked).map(\.action) == [.selectPreset("MacBook 14 120 Hz")])
        #expect(at60.filter(\.isChecked).map(\.action) == [.selectPreset("MacBook 14")])
    }

    /// A rate the name already says isn't said again after it.
    @Test func aTitleDoesNotRepeatTheRateInItsName() throws {
        let presets = [
            Preset(name: "MacBook 14 120 Hz", lookslike: "1728x1080", hidpi: true, hz: 120),
            Preset(name: "Desk 144 hz", lookslike: "1920x1080", hidpi: false, hz: 144),
            Preset(name: "Says 120 Hz", lookslike: "1728x1080", hidpi: true, hz: 90),
        ]

        let children = try item("Resolution", in: build(session(), presets: presets)).children

        #expect(children.prefix(3).map(\.title) == [
            "MacBook 14 120 Hz (1728x1080)",
            "Desk 144 hz (1920x1080, 1x)",
            "Says 120 Hz (1728x1080, 90 Hz)",
        ])
    }

    // MARK: Refresh rate

    @Test func refreshRateOffersSixtyAndOneTwenty() throws {
        let rate = try item("Refresh Rate", in: build(session()))

        #expect(rate.action == nil)
        #expect(rate.isEnabled)
        #expect(rate.children.map(\.title) == ["60 Hz", "120 Hz"])
        #expect(rate.children.map(\.action) == [.selectRefreshRate(60), .selectRefreshRate(120)])
        #expect(rate.children.allSatisfy { $0.isEnabled })
    }

    /// The checkmark follows the live rate, whatever size the session has.
    @Test(arguments: [60, 120])
    func refreshRateChecksTheLiveRate(hz: Int) throws {
        let oneX = session(looksLike: ScreenSize(w: 1920, h: 1080), pixels: ScreenSize(w: 1920, h: 1080), hz: hz)

        for status in [session(hz: hz), oneX, session(.degraded, hz: hz)] {
            let rate = try item("Refresh Rate", in: build(status))
            #expect(rate.children.filter(\.isChecked).map(\.title) == ["\(hz) Hz"])
        }
    }

    /// A session at another rate, from a hand-edited preset, shows that rate checked, as Resolution does
    /// for a size that isn't saved, and it can't be chosen.
    @Test func anotherRateIsShownCheckedAndDisabled() throws {
        let rate = try item("Refresh Rate", in: build(session(hz: 144)))

        #expect(rate.children.map(\.title) == ["60 Hz", "120 Hz", "144 Hz"])
        #expect(rate.children.map(\.isChecked) == [false, false, true])
        let last = try #require(rate.children.last)
        #expect(!last.isEnabled)
        #expect(last.action == StatusMenuAction.none)
    }

    @Test func idleHasNoRefreshRate() {
        #expect(!build(idle).map(\.title).contains("Refresh Rate"))
    }

    @Test func safeModeLineAppears() throws {
        #expect(!build(idle).map(\.title).contains("Safe mode"))

        let items = build(idle, safeMode: true)

        #expect(Array(items.map(\.title).prefix(2)) == ["No session", "Safe mode"])
        #expect(try item("Safe mode", in: items).isEnabled == false)
        #expect(try item("Safe mode", in: items).action == nil)
    }

    /// The spec's order, in groups: what's going on, the session, the settings, then the app itself.
    @Test func itemOrderMatchesSpec() {
        #expect(layout(build(session(), safeMode: true)) == [
            "Session: parsec, 1728x1080",
            "Safe mode",
            "-",
            "Resolution",
            "Refresh Rate",
            "End Session",
            "Reconnect All Displays",
            "-",
            "Edit Presets...",
            "Launch at Login",
            "-",
            "Restart",
            "Quit",
        ])
        #expect(layout(build(idle)) == [
            "No session",
            "-",
            "End Session",
            "Reconnect All Displays",
            "-",
            "Edit Presets...",
            "Launch at Login",
            "-",
            "Restart",
            "Quit",
        ])
    }

    /// With or without a session, and in a dry run, which edits its own copy of the files.
    @Test func editPresetsOpensTheWindow() throws {
        for items in [build(idle), build(session()), build(session(.degraded), safeMode: true, dryRun: true)] {
            let edit = try item("Edit Presets...", in: items)
            #expect(edit.action == .editPresets)
            #expect(edit.isEnabled)
            #expect(edit.title.hasSuffix("s..."), "Three periods, not an ellipsis character")
        }
    }

    @Test func separatorsCantBeChosen() {
        let separators = build(session(.degraded), safeMode: true, dryRun: true).filter(\.isSeparator)

        #expect(separators.count == 3)
        #expect(separators.allSatisfy { $0.title.isEmpty && $0.action == nil && !$0.isEnabled && $0.children.isEmpty })
    }

    @Test func actionsMatchTheirItems() throws {
        let items = build(session())

        #expect(try item("End Session", in: items).action == .endSession)
        #expect(try item("Reconnect All Displays", in: items).action == .reconnectAll)
        #expect(try item("Reconnect All Displays", in: items).isEnabled)
        #expect(try item("Launch at Login", in: items).action == .toggleLaunchAtLogin)
        #expect(try item("Restart", in: items).action == .restart)
        #expect(try item("Restart", in: items).isEnabled)
        #expect(try item("Quit", in: items).action == .quit)
    }

    @Test func launchAtLoginShowsItsState() throws {
        #expect(try item("Launch at Login", in: build(idle, launchAtLogin: true)).isChecked)
        #expect(try item("Launch at Login", in: build(idle, launchAtLogin: false)).isChecked == false)
    }

    @Test func noBetterDisplayText() {
        let everything = allTitles(build(session(), safeMode: true)) + allTitles(build(idle))
            + allTitles(build(session(.degraded), dryRun: true))

        #expect(!everything.isEmpty)
        #expect(everything.allSatisfy { !$0.lowercased().contains("betterdisplay") })
    }

    // MARK: Dry run

    /// A dry-run copy has the real app's icon, so every state it can show starts by saying what it is.
    @Test(arguments: [SessionState.idle, .starting, .active, .degraded, .ending])
    func dryRunStartsTheStateLine(state: SessionState) throws {
        let status = state == .idle ? idle : session(state)
        let real = try #require(build(status).first)

        let dry = try #require(build(status, dryRun: true).first)

        #expect(dry.title == "Dry run: \(real.title)")
        #expect(dry.isEnabled == false && dry.action == nil)
    }

    @Test func dryRunKeepsEverythingElse() {
        let real = build(session(), safeMode: true)
        let dry = build(session(), safeMode: true, dryRun: true)

        #expect(layout(dry).dropFirst() == layout(real).dropFirst())
        #expect(dry.dropFirst().map(\.action) == real.dropFirst().map(\.action))
        #expect(dry.first { $0.title == "Resolution" } == real.first { $0.title == "Resolution" })
        #expect(dry.first { $0.title == "Refresh Rate" } == real.first { $0.title == "Refresh Rate" })
    }

    /// The copy Restart opens gets none of the dry run's environment, so it would be the real app.
    @Test func dryRunTurnsRestartOff() throws {
        let items = build(session(), dryRun: true)

        #expect(try item("Restart", in: items).isEnabled == false)
        let others = items.filter { $0.action != nil && $0.action != .restart }
        #expect(others.allSatisfy { $0.isEnabled }, "Everything else in a dry run stays on the simulated copy")
    }

    @Test func statusItemSaysDryOnlyForADryRun() {
        #expect(StatusMenuModel.statusItemTitle(dryRun: true) == "DRY")
        #expect(StatusMenuModel.statusItemTitle(dryRun: false) == nil)
        #expect(StatusMenuModel.statusItemDescription(dryRun: true) == "Porch Light, dry run")
        #expect(StatusMenuModel.statusItemDescription(dryRun: false) == "Porch Light")
    }
}
