import ADModel

/// One change inside a configuration transaction.
public enum DisplayChange: Sendable, Equatable {
    case origin(DisplayID, DisplayOrigin)
    case mode(DisplayID, DisplayMode)
}

/// A display call that failed. `code` is the `CGError` raw value where there is one: 1001 for an
/// offline target, as the spike saw, and 1014 for an enable with every display asleep.
public struct DisplayBackendError: Error, Equatable {
    public var code: Int32
    public var message: String
    /// Only from a commit: the displays whose mode was left out because they didn't list it. Everything
    /// else in that commit was applied. Empty for any other failure, where nothing was.
    public var modesNotApplied: [DisplayID]

    public init(code: Int32, message: String, modesNotApplied: [DisplayID] = []) {
        self.code = code
        self.message = message
        self.modesNotApplied = modesNotApplied
    }
}

/// The seam between everything above it and the real displays.
///
/// `setEnabled` and `commit` can block for about 10 seconds on real hardware, so they must never
/// run on the main actor. Changes last for the login session and never persist across a restart.
public protocol DisplayBackend: AnyObject, Sendable {
    /// Every display the system lists, including disconnected ones and empty pipes. While the OS
    /// fallback display is up, that is only the fallback. A disconnected display has a nil UUID, a
    /// nil name and a nil mode. Its origin is the one it had when it went off.
    func topology() -> Topology

    /// Every mode the display offers, including low-resolution duplicates. Empty unless it's online.
    func modes(of id: DisplayID) -> [DisplayMode]

    /// Turns a monitor on or off, by the ID recorded before it went off.
    func setEnabled(_ id: DisplayID, _ enabled: Bool) throws

    /// Turns several monitors on or off in one transaction, so macOS reconfigures once: all of them or,
    /// if one can't be queued, none, with an error that names it. An empty list does nothing. A session
    /// uses this because turning the last monitor off in a transaction of its own sometimes stalls for
    /// 10 seconds (Porch Light spec, section 4.3).
    func setEnabled(_ ids: [DisplayID], _ enabled: Bool) throws

    /// Applies all the changes as one transaction, or none of them. One offline target fails it. The
    /// exception is a mode the display doesn't list: that change is left out, the rest is applied, and
    /// then this throws an error whose `modesNotApplied` names the display.
    func commit(_ changes: [DisplayChange]) throws
}
