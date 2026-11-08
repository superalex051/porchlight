import ADFoundation
import Carbon.HIToolbox

/// The shortcuts that are a way out from the Mac's own keyboard, all on Control+Option+Command:
/// Escape force-ends any session and reconnects the displays, R restarts the app and Q quits it.
public enum EmergencyHotkeys {
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    public static let rescue = Hotkey(keyCode: UInt32(kVK_Escape), modifiers: modifiers)
    public static let restart = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers)
    public static let quit = Hotkey(keyCode: UInt32(kVK_ANSI_Q), modifiers: modifiers)

    /// Tries all three even if one fails, because each key that works is still a way out. Logs every
    /// failure, then throws the first.
    public static func register(
        on registry: any HotkeyRegistering,
        rescue rescueAction: @escaping @Sendable () -> Void,
        restart restartAction: @escaping @Sendable () -> Void,
        quit quitAction: @escaping @Sendable () -> Void
    ) throws {
        let entries: [(name: String, hotkey: Hotkey, action: @Sendable () -> Void)] = [
            ("rescue", rescue, rescueAction),
            ("restart", restart, restartAction),
            ("quit", quit, quitAction),
        ]

        var firstFailure: (any Error)?
        for entry in entries {
            do {
                try registry.register(entry.hotkey, action: entry.action)
            } catch {
                ADLog.logger("hotkeys").error(
                    "The \(entry.name, privacy: .public) hotkey may not work: \(String(describing: error), privacy: .public)"
                )
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }
}
