import ADSafety
import Testing

// MARK: - What the alert says

@Test func theAlertTitleAndTimeout() {
    #expect(GuardianAlert.title == "Porch Light needs attention")
    #expect(GuardianAlert.timeoutSeconds == 600)
}

@Test func theRestoreFailureAlertSaysWhatHappenedAndHowToRescue() {
    #expect(
        GuardianAlert.message(for: .restoresFailed) == """
            The guardian could not bring the monitors back after 3 tries. It keeps trying every 60 seconds.

            If a monitor is still dark, run this on this Mac:
            /Applications/PorchLight.app/Contents/Helpers/porchlight rescue

            Or from another computer:
            ssh <your-mac> /Applications/PorchLight.app/Contents/Helpers/porchlight rescue

            This window closes itself in 10 minutes.
            """
    )
}

/// The command for this Mac is the CLI's full path, because `porchlight` alone works only once
/// `install.sh --link-cli` has linked it.
@Test func theRescueCommandWorksWithoutTheLink() {
    #expect(GuardianAlert.rescueCommand == "/Applications/PorchLight.app/Contents/Helpers/porchlight rescue")
}

/// The notification says what the window says, in one line, from the same title and command. AppleScript
/// quotes it, so it has no double quote or backslash.
@Test func theNotificationSaysWhatTheWindowSays() {
    #expect(
        GuardianAlert.notification
            == "Porch Light needs attention. If a display is dark, run"
            + " /Applications/PorchLight.app/Contents/Helpers/porchlight rescue. See guardian.log."
    )
    #expect(GuardianAlert.notification.hasPrefix(GuardianAlert.title + "."))
    #expect(GuardianAlert.notification.contains("run \(GuardianAlert.rescueCommand)."))
    #expect(!GuardianAlert.notification.contains("\"") && !GuardianAlert.notification.contains("\\"))
    for reason in [GuardianAlert.Reason.restoresFailed, .ledgerUnreadable] {
        #expect(GuardianAlert.message(for: reason).contains("\n\(GuardianAlert.rescueCommand)\n"))
    }
}

/// The guardian also tells the user when it can't read the ledger. It hasn't tried 3 restores then,
/// so the alert must not say it has.
@Test func theUnreadableLedgerAlertSaysWhatHappenedAndHowToRescue() {
    #expect(
        GuardianAlert.message(for: .ledgerUnreadable) == """
            The guardian can't read its record of the session, so it can't tell whether the monitors are back.

            If a monitor is still dark, run this on this Mac:
            /Applications/PorchLight.app/Contents/Helpers/porchlight rescue

            Or from another computer:
            ssh <your-mac> /Applications/PorchLight.app/Contents/Helpers/porchlight rescue

            This window closes itself in 10 minutes.
            """
    )
}

// MARK: - The alert subcommand's arguments

private let validArguments = ["alert", "--title", "T", "--message", "M", "--timeout", "600"]

@Test func alertArgumentsParse() {
    #expect(AlertRequest(arguments: validArguments) == AlertRequest(title: "T", message: "M", timeoutSeconds: 600))
}

@Test func alertArgumentsMayComeInAnyOrder() {
    let arguments = ["alert", "--timeout", "5", "--message", "M", "--title", "T"]
    #expect(AlertRequest(arguments: arguments) == AlertRequest(title: "T", message: "M", timeoutSeconds: 5))
}

/// What the guardian passes is what the child reads back, even text that looks like a flag.
@Test func alertArgumentsRoundTrip() {
    let request = AlertRequest(
        title: GuardianAlert.title,
        message: "--title\n\nline two",
        timeoutSeconds: GuardianAlert.timeoutSeconds
    )
    #expect(request.arguments.first == "alert")
    #expect(AlertRequest(arguments: request.arguments) == request)
}

@Test(arguments: [
    [],
    ["alert"],
    ["restore", "--title", "T", "--message", "M", "--timeout", "600"],
    ["alert", "--message", "M", "--timeout", "600"],
    ["alert", "--title", "T", "--timeout", "600"],
    ["alert", "--title", "T", "--message", "M"],
    ["alert", "--title", "T", "--message", "M", "--timeout"],
    ["alert", "--title", "T", "--title", "U", "--message", "M", "--timeout", "600"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "600", "--level", "8"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "600", "extra"],
    ["alert", "--title", "", "--message", "M", "--timeout", "600"],
    ["alert", "--title", "T", "--message", "", "--timeout", "600"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "0"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "-5"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "1.5"],
    ["alert", "--title", "T", "--message", "M", "--timeout", "ten"],
    ["alert", "--title", "T", "--message", "M", "--timeout", ""],
])
func badAlertArgumentsAreRefused(_ arguments: [String]) {
    #expect(AlertRequest(arguments: arguments) == nil)
}
