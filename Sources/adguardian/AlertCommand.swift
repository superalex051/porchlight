import ADSafety
import AppKit

/// `adguardian alert`, which the guardian starts with its notification: one panel above other windows,
/// on every Space and over full-screen apps, until OK or the timeout. A window, because macOS mutes
/// notification banners while the display is shared. It runs as an accessory app, with no Dock icon,
/// and needs no Info.plist. Only the guardian's own child runs this, never the watching process.
@MainActor
enum AlertCommand {
    /// 2 for arguments it can't read, before anything shows. Otherwise it doesn't return: the panel
    /// ends the process with 0 when it closes.
    static func run(_ arguments: [String]) -> Int32 {
        guard let request = AlertRequest(arguments: arguments) else {
            GuardianLog.writeToStandardError(AlertRequest.usage)
            return 2
        }
        show(request)
    }

    private static func show(_ request: AlertRequest) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        let panel = AlertPanel(request)
        panel.show()
        app.run()
        // Nothing stops the run loop, but if it ever returned, the panel would be gone with it.
        exit(0)
    }

    /// Never on screen, because an accessory app has no menu bar, but its key equivalents make
    /// Command-C copy a selected command.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let menu = NSMenu()
        // The first item is the application menu.
        menu.addItem(NSMenuItem())
        menu.addItem(editItem)
        return menu
    }
}

@MainActor
private final class AlertPanel: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 500
    private static let inset: CGFloat = 20

    private let panel: NSPanel
    private let timeoutSeconds: Int

    init(_ request: AlertRequest) {
        timeoutSeconds = request.timeoutSeconds
        // Non-activating, so it doesn't take the keyboard from whatever the user is typing into, where a
        // Return would close it unread. A click makes it key, and then Return is OK.
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = request.title
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A panel hides when its app stops being active, which a click elsewhere does.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = content(for: request)
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
    }

    /// Centered on the main display, which is the one Parsec streams.
    func show() {
        if let area = NSScreen.screens.first?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        Timer.scheduledTimer(
            timeInterval: TimeInterval(timeoutSeconds),
            target: self,
            selector: #selector(timedOut),
            userInfo: nil,
            repeats: false
        )
    }

    private func content(for request: AlertRequest) -> NSView {
        let heading = NSTextField(labelWithString: request.title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)

        // Selectable, so a rescue command can be copied.
        let message = NSTextField(wrappingLabelWithString: request.message)
        message.isSelectable = true
        message.preferredMaxLayoutWidth = Self.width - 2 * Self.inset

        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed))
        // The default button: Return presses it once the panel is key.
        ok.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([ok], in: .trailing)

        let stack = NSStackView(views: [heading, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        NSLayoutConstraint.activate(
            [stack.widthAnchor.constraint(equalToConstant: Self.width)]
                + [heading, message, buttons].map {
                    $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset)
                }
        )
        return stack
    }

    @objc private func okPressed() {
        finish()
    }

    @objc private func timedOut() {
        finish()
    }

    /// The title bar's close button.
    func windowWillClose(_ notification: Notification) {
        finish()
    }

    /// Nothing to clean up, and `NSApp.stop` from a timer waits for an event that may never come.
    private func finish() {
        exit(0)
    }
}
