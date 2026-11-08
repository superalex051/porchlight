import Foundation

/// A window that comes with the guardian's notification. macOS mutes notification banners while the
/// display is shared ("muted by display state (displayShared)"), which is when Parsec is connected, and
/// a window isn't muted.
public protocol UserAlerting: Sendable {
    /// Returns at once. The window closes itself after `timeoutSeconds`.
    func showAlert(title: String, message: String, timeoutSeconds: Int)
    /// True while a window this process asked for is still up.
    var isShowingAlert: Bool { get }
}

/// What the alert window says.
public enum GuardianAlert {
    public enum Reason: Sendable {
        /// `GuardianPolicy.maxRestores` restores failed, and the retries go on.
        case restoresFailed
        /// The ledger couldn't be read, so the guardian can't know what to bring back.
        case ledgerUnreadable
    }

    public static let title = "Porch Light needs attention"
    /// What a person runs on this Mac to bring the monitors back. The full path, because `porchlight`
    /// alone works only once `install.sh --link-cli` has linked it.
    public static let rescueCommand = "/Applications/PorchLight.app/Contents/Helpers/porchlight rescue"
    /// The notification that comes with the window says the same in one line. AppleScript quotes it, so
    /// it has no double quote or backslash.
    public static let notification = "\(title). If a display is dark, run \(rescueCommand). See guardian.log."
    /// Long enough to be seen on a return to the Mac, and a window nobody saw doesn't stay for good.
    public static let timeoutSeconds = 600

    public static func message(for reason: Reason) -> String {
        let what: String
        switch reason {
        case .restoresFailed:
            what = "The guardian could not bring the monitors back after \(GuardianPolicy.maxRestores) tries. "
                + "It keeps trying every \(Int(GuardianPolicy.restoreRetryInterval)) seconds."
        case .ledgerUnreadable:
            what = "The guardian can't read its record of the session, so it can't tell whether the monitors are back."
        }
        return """
            \(what)

            If a monitor is still dark, run this on this Mac:
            \(rescueCommand)

            Or from another computer:
            ssh <your-mac> \(rescueCommand)

            This window closes itself in \(timeoutSeconds / 60) minutes.
            """
    }
}

/// The guardian's `alert` subcommand: `alert --title <text> --message <text> --timeout <seconds>`. The
/// guardian runs its own binary with these, and the child shows the window.
public struct AlertRequest: Sendable, Equatable {
    public static let subcommand = "alert"
    public static let usage = "usage: porchlight-guardian alert --title <text> --message <text> --timeout <seconds>"

    private static let titleFlag = "--title"
    private static let messageFlag = "--message"
    private static let timeoutFlag = "--timeout"

    public var title: String
    public var message: String
    public var timeoutSeconds: Int

    public init(title: String, message: String, timeoutSeconds: Int) {
        self.title = title
        self.message = message
        self.timeoutSeconds = timeoutSeconds
    }

    /// Everything after the program's path, starting with the subcommand. Nil unless each flag comes
    /// exactly once with a value, the texts aren't empty, and the timeout is a whole number of seconds
    /// above 0. A value is taken as it is, even one that looks like a flag.
    public init?(arguments: [String]) {
        guard arguments.first == Self.subcommand else { return nil }
        var values: [String: String] = [:]
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard [Self.titleFlag, Self.messageFlag, Self.timeoutFlag].contains(flag),
                values[flag] == nil,
                let value = rest.popFirst()
            else { return nil }
            values[flag] = value
        }
        guard let title = values[Self.titleFlag], !title.isEmpty,
            let message = values[Self.messageFlag], !message.isEmpty,
            let timeout = values[Self.timeoutFlag].flatMap({ Int($0) }), timeout > 0
        else { return nil }
        self.init(title: title, message: message, timeoutSeconds: timeout)
    }

    /// What `init(arguments:)` reads back.
    public var arguments: [String] {
        [
            Self.subcommand,
            Self.titleFlag, title,
            Self.messageFlag, message,
            Self.timeoutFlag, String(timeoutSeconds),
        ]
    }
}
