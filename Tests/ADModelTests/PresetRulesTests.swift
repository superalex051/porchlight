import ADModel
import Testing

private func preset(_ name: String, _ lookslike: String = "1728x1080", hz: Int = 60) -> Preset {
    Preset(name: name, lookslike: lookslike, hidpi: true, hz: hz)
}

@Suite struct PresetRulesTests {
    @Test func everyBuiltInPasses() {
        #expect(Presets.builtIn.allSatisfy { PresetRules.problem(with: $0) == nil })
        #expect(PresetRules.problem(with: Presets.builtIn) == nil)
    }

    @Test func aNameIsNeeded() {
        #expect(PresetRules.problem(with: preset("")) == "a preset needs a name")
        #expect(PresetRules.problem(with: preset("   ")) == "a preset needs a name")
    }

    /// `-preset=auto` asks Porch Light to choose, so a preset by that name could never be picked.
    @Test func autoIsKept() {
        #expect(PresetRules.problem(with: preset("auto")) == "the name auto is kept for -preset=auto")
        #expect(PresetRules.problem(with: preset(" AUTO ")) == "the name auto is kept for -preset=auto")
        #expect(PresetRules.problem(with: preset("Auto Mac")) == nil)
    }

    @Test func theSizeAndRateGetTheSessionLimits() {
        #expect(PresetRules.problem(with: preset("A", "big")) == "lookslike must be a size such as 1728x1080")
        #expect(PresetRules.problem(with: preset("A", "100x1080")) == "lookslike width must be 640 to 3840")
        #expect(PresetRules.problem(with: preset("A", "1728x100")) == "lookslike height must be 360 to 2400")
        #expect(PresetRules.problem(with: preset("A", hz: 1000)) == "hz must be 24 to 240")
        #expect(PresetRules.problem(with: preset("A", "3840x2400", hz: 240)) == nil)
    }

    @Test func aListNamesItsFirstProblem() {
        let list = [preset("Good"), preset("Bad", "100x1080"), preset("")]

        #expect(PresetRules.problem(with: list) == "Bad: lookslike width must be 640 to 3840")
    }

    /// As `-preset=` compares them.
    @Test func twoPresetsCantShareANameInAnyCase() {
        #expect(PresetRules.problem(with: [preset("MacBook 14"), preset("macbook 14 ")]) == "two presets are called macbook 14")
        #expect(PresetRules.problem(with: [preset("MacBook 14"), preset("MacBook 14 120 Hz")]) == nil)
    }

    @Test func anEmptyListIsAllowed() {
        #expect(PresetRules.problem(with: []) == nil)
    }

    @Test func cleanNameDropsSpacesAtEitherEnd() {
        #expect(PresetRules.cleanName("  My Mac \n") == "My Mac")
    }
}

@Suite struct PresetRenameTests {
    private let mapping = ClientMapping(
        autoSize: true,
        clients: [
            ClientRule(name: "MacBook", address: "192.168.0.232", preset: "MacBook 14 120 Hz"),
            ClientRule(name: "iPad", address: "192.168.0.10", preset: "iPad"),
            ClientRule(name: "Office", address: "128.227.3.94", preset: "4K Screen"),
        ]
    )

    @Test func aClientFollowsItsRenamedPreset() {
        let renamed = mapping.renamingPresets([PresetRename(from: "MacBook 14 120 Hz", to: "MacBook 120")])

        #expect(renamed.clients.map(\.preset) == ["MacBook 120", "iPad", "4K Screen"])
        #expect(renamed.autoSize)
        #expect(renamed.clients.map(\.name) == mapping.clients.map(\.name))
        #expect(renamed.clients.map(\.match) == mapping.clients.map(\.match))
    }

    /// A client may have written the name in another case.
    @Test func namesCompareWithoutCase() {
        let renamed = mapping.renamingPresets([PresetRename(from: "IPAD", to: "iPad Air")])

        #expect(renamed.clients.map(\.preset) == ["MacBook 14 120 Hz", "iPad Air", "4K Screen"])
    }

    /// All at once, so two presets can trade names and their clients trade with them.
    @Test func renamesApplyTogether() {
        let renamed = mapping.renamingPresets([
            PresetRename(from: "iPad", to: "4K Screen"),
            PresetRename(from: "4K Screen", to: "iPad"),
        ])

        #expect(renamed.clients.map(\.preset) == ["MacBook 14 120 Hz", "4K Screen", "iPad"])
    }

    @Test func noRenameChangesNothing() {
        #expect(mapping.renamingPresets([]) == mapping)
        #expect(mapping.renamingPresets([PresetRename(from: "Nobody's", to: "Still nobody's")]) == mapping)
    }
}
