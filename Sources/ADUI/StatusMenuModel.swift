import ADModel

/// What choosing a menu item does. An item with a nil action is a line of text or a submenu's title.
/// `none` is a choice that does nothing: the current size or rate, when it isn't one the menu offers.
/// `reconnectAll` runs the `rescue` operation, the same as the emergency hotkey. `selectRefreshRate`
/// changes only the rate, so the session keeps its size. `editPresets` opens the presets window.
nonisolated public enum StatusMenuAction: Equatable, Sendable {
    case endSession, reconnectAll, editPresets, toggleLaunchAtLogin, restart, quit
    case selectPreset(String), selectRefreshRate(Int), none
}

nonisolated public struct StatusMenuItem: Equatable, Sendable {
    public var title: String
    public var action: StatusMenuAction?
    public var isEnabled: Bool
    public var isChecked: Bool
    public var children: [StatusMenuItem]
    /// A line between groups. It has no title and can't be chosen.
    public var isSeparator: Bool

    public init(
        title: String,
        action: StatusMenuAction? = nil,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        children: [StatusMenuItem] = [],
        isSeparator: Bool = false
    ) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
        self.isSeparator = isSeparator
    }

    public static let separator = StatusMenuItem(title: "", isEnabled: false, isSeparator: true)
}

/// The status menu's content, as a value, so it can be tested without AppKit.
nonisolated public enum StatusMenuModel {
    /// Beside the icon of a dry-run copy, so it can't be taken for the real app, which has the same icon.
    public static let dryRunLabel = "DRY"

    /// What the Refresh Rate submenu offers. 120 is for the MacBook Pro's 120 Hz screen.
    public static let refreshRates = [60, 120]

    /// What the status item says beside its icon: nothing for the real app.
    public static func statusItemTitle(dryRun: Bool) -> String? {
        dryRun ? dryRunLabel : nil
    }

    /// What VoiceOver and accessibility tools read for the status item.
    public static func statusItemDescription(dryRun: Bool) -> String {
        dryRun ? "Porch Light, dry run" : "Porch Light"
    }

    /// `dryRun` marks a copy that only works on a simulated copy of the displays. Its state line says so,
    /// and Restart is off, because the copy it would open gets none of this one's environment, so it
    /// would be the real app, on the real displays.
    public static func build(
        status: SessionStatus,
        presets: [Preset],
        safeMode: Bool,
        launchAtLogin: Bool,
        dryRun: Bool = false
    ) -> [StatusMenuItem] {
        let line = stateLine(status)
        var items = [StatusMenuItem(title: dryRun ? "Dry run: \(line)" : line, isEnabled: false)]
        if status.state == .degraded {
            items.append(StatusMenuItem(title: "Stopped holding the layout, see session.log", isEnabled: false))
        }
        if safeMode {
            items.append(StatusMenuItem(title: "Safe mode", isEnabled: false))
        }
        items.append(.separator)
        // A degraded session can still be resized, and whoever is connected to it may need that most.
        if status.state == .active || status.state == .degraded {
            items.append(StatusMenuItem(title: "Resolution", children: sizes(status, presets)))
            items.append(StatusMenuItem(title: "Refresh Rate", children: rates(status)))
        }
        items += [
            StatusMenuItem(title: "End Session", action: .endSession, isEnabled: status.state != .idle),
            StatusMenuItem(title: "Reconnect All Displays", action: .reconnectAll),
            .separator,
            // The periods say it opens a window. Three plain ones, not the ellipsis character.
            StatusMenuItem(title: "Edit Presets...", action: .editPresets),
            StatusMenuItem(title: "Launch at Login", action: .toggleLaunchAtLogin, isChecked: launchAtLogin),
            .separator,
            StatusMenuItem(title: "Restart", action: .restart, isEnabled: !dryRun),
            StatusMenuItem(title: "Quit", action: .quit),
        ]
        return items
    }

    /// A session on its way up or down, or one that stopped enforcing, says so.
    private static func stateLine(_ status: SessionStatus) -> String {
        guard status.state != .idle else { return "No session" }
        let details = [status.client, status.looksLike?.description].compactMap { $0 }
        let line = details.isEmpty ? "Session" : "Session: \(details.joined(separator: ", "))"
        return status.state == .active ? line : "\(line) (\(status.state.rawValue))"
    }

    private static func sizes(_ status: SessionStatus, _ presets: [Preset]) -> [StatusMenuItem] {
        var items = presets.map { preset in
            StatusMenuItem(
                title: title(of: preset),
                action: .selectPreset(preset.name),
                isChecked: isCurrent(preset, status)
            )
        }
        if !items.contains(where: \.isChecked), let looksLike = status.looksLike, let pixels = status.pixels, let hz = status.hz {
            items.append(
                StatusMenuItem(
                    title: "\(looksLike) (\(pixels) pixels, \(hz) Hz)",
                    action: StatusMenuAction.none,
                    isEnabled: false,
                    isChecked: true
                )
            )
        }
        return items
    }

    /// Each rate the menu offers, checked if it's the live one. A live rate the menu doesn't offer is
    /// shown too, checked and disabled, as `sizes` does for a size that isn't saved.
    private static func rates(_ status: SessionStatus) -> [StatusMenuItem] {
        var items = refreshRates.map { hz in
            StatusMenuItem(title: "\(hz) Hz", action: .selectRefreshRate(hz), isChecked: status.hz == hz)
        }
        if let hz = status.hz, !refreshRates.contains(hz) {
            items.append(
                StatusMenuItem(title: "\(hz) Hz", action: StatusMenuAction.none, isEnabled: false, isChecked: true)
            )
        }
        return items
    }

    /// The size, and only what sets it apart from the usual: 1x, because 4K Screen and 1080p Screen both
    /// look like 1920x1080, and a rate other than 60 Hz that the name doesn't already say.
    private static func title(of preset: Preset) -> String {
        var details = [preset.lookslike]
        if !preset.hidpi { details.append("1x") }
        let rate = "\(preset.hz) Hz"
        if preset.hz != 60, !preset.name.lowercased().contains(rate.lowercased()) { details.append(rate) }
        return "\(preset.name) (\(details.joined(separator: ", ")))"
    }

    /// By everything a preset sets, because 4K Screen and 1080p Screen differ only in their pixels.
    private static func isCurrent(_ preset: Preset, _ status: SessionStatus) -> Bool {
        ScreenSize(parsing: preset.lookslike) == status.looksLike
            && preset.pixels == status.pixels
            && preset.hz == status.hz
    }
}
