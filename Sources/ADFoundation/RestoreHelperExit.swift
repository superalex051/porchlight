/// How `adguardian restore` exits, for the guardian and the CLI that run it. On stdout it prints the
/// name of each display that came back but not at its recorded mode, one a line, and nothing else.
public enum RestoreHelperExit {
    /// `rescued` is written. Any display named on stdout was found without its recorded mode by two
    /// fresh processes in a row, so the mode is taken to be gone.
    public static let restored: Int32 = 0
    public static let failed: Int32 = 1
    /// Every recorded display is back where it was, but the ones named on stdout aren't at their recorded
    /// mode. `rescued` isn't written, because a process that started while a monitor was off may never
    /// see that monitor's modes, and a fresh one can. Run it again.
    public static let modesNotRestored: Int32 = 3
}
