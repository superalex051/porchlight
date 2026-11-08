/// A notification after a command from the status menu or an emergency hotkey, which have no window to
/// show an answer in. Only a failure or a warning gets one: the menu shows the rest.
nonisolated public struct StatusNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var isError: Bool

    public init(title: String, body: String, isError: Bool) {
        self.title = title
        self.body = body
        self.isError = isError
    }

    /// Nil if it went as asked. The engine's reasons are written to follow `Failed. ` on a command line,
    /// so they start in lower case and have no full stop. Here each one reads as a sentence.
    public static func after(_ action: StatusMenuAction, ok: Bool, reason: String?, warning: String?) -> StatusNotice? {
        guard let words = words(for: action) else { return nil }
        if !ok {
            return StatusNotice(
                title: words.failed,
                body: sentence(reason) ?? "No reason was given. See session.log in ~/Library/Logs/PorchLight.",
                isError: true
            )
        }
        guard let body = sentence(warning) else { return nil }
        return StatusNotice(title: words.doneWithWarning, body: body, isError: false)
    }

    public static func restartFailed(_ reason: String) -> StatusNotice {
        StatusNotice(title: "Couldn't restart", body: sentence(reason) ?? reason, isError: true)
    }

    public static let launchAtLoginNeedsApproval = StatusNotice(
        title: "Launch at Login needs approval",
        body: "Turn on Porch Light in System Settings, under Login Items.",
        isError: false
    )

    private static func words(for action: StatusMenuAction) -> (failed: String, doneWithWarning: String)? {
        switch action {
        case .endSession: ("Couldn't end the session", "Session ended")
        case .reconnectAll: ("Couldn't reconnect the displays", "Displays reconnected")
        case .selectPreset: ("Couldn't change the resolution", "Resolution changed")
        case .selectRefreshRate: ("Couldn't change the refresh rate", "Refresh rate changed")
        case .toggleLaunchAtLogin: ("Couldn't change Launch at Login", "Launch at Login changed")
        case .editPresets, .restart, .quit, .none: nil
        }
    }

    /// The first letter in upper case and a full stop at the end. Nil for no text at all.
    static func sentence(_ text: String?) -> String? {
        guard let text, let first = text.first else { return nil }
        let capitalized = first.uppercased() + text.dropFirst()
        guard let last = capitalized.last, !".!?".contains(last) else { return capitalized }
        return capitalized + "."
    }
}
