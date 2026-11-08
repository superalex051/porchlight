import Testing

@testable import ADUI

@Suite struct StatusNoticeTests {
    /// Each title says what didn't happen, in the same form, and the body is the reason as a sentence.
    @Test func failuresSayWhatDidntHappen() {
        let cases: [(StatusMenuAction, String)] = [
            (.endSession, "Couldn't end the session"),
            (.reconnectAll, "Couldn't reconnect the displays"),
            (.selectPreset("MacBook 14"), "Couldn't change the resolution"),
            (.selectRefreshRate(120), "Couldn't change the refresh rate"),
            (.toggleLaunchAtLogin, "Couldn't change Launch at Login"),
        ]
        for (action, title) in cases {
            let notice = StatusNotice.after(action, ok: false, reason: "a display did not come back correctly", warning: nil)

            #expect(notice == StatusNotice(title: title, body: "A display did not come back correctly.", isError: true))
        }
    }

    /// A refusal with no reason still says where to look.
    @Test func aFailureWithNoReasonPointsAtTheLog() throws {
        for reason in [nil, ""] as [String?] {
            let notice = try #require(StatusNotice.after(.endSession, ok: false, reason: reason, warning: nil))

            #expect(notice.body == "No reason was given. See session.log in ~/Library/Logs/PorchLight.")
        }
    }

    /// The spec's warning for an unplugged monitor, after an end or a rescue, under a title that says it
    /// still worked. Before, the title was only the app's name, which the system shows anyway.
    @Test func warningsSayItWorked() {
        let warning = "not restored: LG 27GL850; not restored at recorded mode: M34WQ"

        #expect(StatusNotice.after(.endSession, ok: true, reason: nil, warning: warning) == StatusNotice(
            title: "Session ended",
            body: "Not restored: LG 27GL850; not restored at recorded mode: M34WQ.",
            isError: false
        ))
        #expect(StatusNotice.after(.reconnectAll, ok: true, reason: nil, warning: warning)?.title == "Displays reconnected")
    }

    @Test func aRateChangeWithAWarningSaysItChanged() {
        #expect(StatusNotice.after(.selectRefreshRate(120), ok: true, reason: nil, warning: "x")?.title == "Refresh rate changed")
    }

    @Test func aPlainSuccessSaysNothing() {
        for action in [StatusMenuAction.endSession, .reconnectAll, .selectPreset("4K Screen"), .selectRefreshRate(60), .toggleLaunchAtLogin] {
            #expect(StatusNotice.after(action, ok: true, reason: nil, warning: nil) == nil)
            #expect(StatusNotice.after(action, ok: true, reason: nil, warning: "") == nil)
        }
    }

    /// These change nothing a notification could report: Restart has its own, and Quit ends the app.
    @Test func restartQuitAndNoneHaveNoMenuNotice() {
        for action in [StatusMenuAction.restart, .quit, .none] {
            #expect(StatusNotice.after(action, ok: false, reason: "restarting", warning: nil) == nil)
        }
        #expect(StatusNotice.restartFailed("the application could not be opened").body == "The application could not be opened.")
    }

    @Test func aSentenceKeepsItsOwnEnding() {
        #expect(StatusNotice.sentence("done.") == "Done.")
        #expect(StatusNotice.sentence("why?") == "Why?")
        #expect(StatusNotice.sentence("x") == "X.")
        #expect(StatusNotice.sentence("") == nil)
        #expect(StatusNotice.sentence(nil) == nil)
    }

    @Test func noBetterDisplayText() {
        let notices = [StatusMenuAction.endSession, .reconnectAll, .selectPreset("x"), .selectRefreshRate(120), .toggleLaunchAtLogin]
            .compactMap { StatusNotice.after($0, ok: false, reason: nil, warning: nil) }
            + [StatusNotice.launchAtLoginNeedsApproval, .restartFailed("x")]

        #expect(notices.count == 7)
        #expect(notices.allSatisfy { !"\($0.title) \($0.body)".lowercased().contains("betterdisplay") })
    }
}
