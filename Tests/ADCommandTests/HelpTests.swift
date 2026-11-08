import ADModel
import Testing

@testable import ADCommand

@Suite struct HelpTests {
    private static let lines = CommandHelp.text.split(separator: "\n", omittingEmptySubsequences: false)

    /// Every selector, key and session parameter a person can type is named, so the help can't fall
    /// behind the registry. `reason` is the menu's, and `dryRunPlan` only answers in a dry run.
    @Test func namesEveryParameter() {
        let unlisted: Set<String> = ["reason", "dryRunPlan", "create", "discard", "deviceType"]
        for feature in FeatureRegistry.all where !unlisted.contains(feature.key) {
            #expect(CommandHelp.text.lowercased().contains("-\(feature.key.lowercased())"), "\(feature.key)")
        }
    }

    @Test func namesEveryOperation() {
        for operation in ["get", "set", "create", "discard", "session start", "session end", "session resize",
                          "session status", "session watch", "session presets", "rescue", "ping", "quit", "help"]
        {
            #expect(CommandHelp.text.contains("  \(operation)"), "\(operation)")
        }
    }

    /// Size per device, and the parameters of its commands, which aren't in the registry.
    @Test func namesSizePerDevice() {
        for text in ["  clients list", "  clients set", "  clients remove", "  clients auto", "-preset=auto",
                     "-address=", "-on|-off", "MacBook 14", "  clients match", "  clients notch",
                     "  clients room -factor=<n>/<d>", "~/.parsec/config.json", "4/3"]
        {
            #expect(CommandHelp.text.contains(text), "\(text)")
        }
    }

    /// The spec's defaults and limits, word for word, because a person picks a size from these.
    @Test func statesTheDefaultsAndLimits() {
        for fact in ["-client=default -lookslike=1728x1080 -hidpi=on -hz=60", "Width 640 to 3840",
                     "height 360 to 2400, hz 24 to 240", "15 by default, 60 for session operations"]
        {
            #expect(CommandHelp.text.contains(fact), "\(fact)")
        }
    }

    /// The names from the Porch Light design, section 2.
    @Test func usesThePorchLightNames() {
        #expect(Self.lines.first == "porchlight: start and end remote sessions with a virtual screen through the Porch Light app.")
        #expect(CommandHelp.text.contains("~/Library/Logs/PorchLight/session.log"))
        let examples = Self.lines.drop { $0 != "Examples" }.dropFirst()
        #expect(!examples.isEmpty && examples.allSatisfy { $0.hasPrefix("  porchlight ") })
    }

    /// It fits a terminal, and follows the project's rules for text a person reads.
    @Test func readsInATerminal() {
        #expect(Self.lines.allSatisfy { $0.count <= 105 }, "\(Self.lines.filter { $0.count > 105 })")
        #expect(!CommandHelp.text.contains("\u{2014}") && !CommandHelp.text.contains("\u{2013}"))
        #expect(!CommandHelp.text.lowercased().contains("betterdisplay"))
        #expect(!CommandHelp.text.hasSuffix("\n"), "The CLI adds the one newline")
        // Its examples work on any Mac, so they name no monitor of this one.
        #expect(!CommandHelp.text.contains("LG") && !CommandHelp.text.contains("M34"))
    }

    @Test(arguments: [
        (["help"], true),
        (["session", "help"], true),
        (["--help"], true),
        (["-h"], true),
        (["rescue", "--Help"], true),
        (["get", "-UUID=help", "-connected"], false),
        (["create", "-type=VirtualScreen", "-virtualScreenName=help"], false),
        (["session", "status"], false),
        ([], false),
    ])
    func isRequestedOnlyByAWordOrAFlag(argv: [String], expected: Bool) throws {
        let (request, _) = try CommandParser.parse(argv)
        #expect(CommandHelp.isRequested(request) == expected, "\(argv)")
    }
}
