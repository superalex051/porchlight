import ADUI
import AppKit

/// Turns `StatusMenuModel`'s value into a real menu. Its content is asked for each time the menu is about
/// to open, and whenever the session changes, so an open menu never shows an old state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// `NSMenuItem.representedObject` needs an object.
    private final class ActionBox: NSObject {
        let action: StatusMenuAction

        init(_ action: StatusMenuAction) {
            self.action = action
        }
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let content: () -> [StatusMenuItem]
    private let perform: (StatusMenuAction) -> Void
    private var shown: [StatusMenuItem] = []

    /// `title` goes beside the icon, as `DRY` does for a dry run. `description` is what accessibility
    /// tools read for the item.
    init(
        title: String?,
        description: String,
        content: @escaping () -> [StatusMenuItem],
        perform: @escaping (StatusMenuAction) -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(
            withLength: title == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
        )
        self.content = content
        self.perform = perform
        super.init()

        // The lantern glyph from the asset catalog, as a template image so it reads in both light and
        // dark menu bars. The SF Symbol is only a fallback for a build without the asset.
        let image = NSImage(named: "MenuBarGlyph")
            ?? NSImage(systemSymbolName: "lightbulb", accessibilityDescription: description)
        image?.isTemplate = true
        image?.accessibilityDescription = description
        if let button = statusItem.button {
            button.image = image
            button.setAccessibilityLabel(description)
            if let title {
                button.title = title
                button.imagePosition = .imageLeading
            }
        }

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        reload()
    }

    /// Does nothing if nothing changed, so an open submenu isn't closed for no reason.
    func reload() {
        let items = content()
        guard items != shown else { return }
        shown = items
        menu.removeAllItems()
        for item in items {
            menu.addItem(makeItem(for: item))
        }
    }

    /// Not `menuWillOpen`, where AppKit says not to change the menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        reload()
    }

    private func makeItem(for item: StatusMenuItem) -> NSMenuItem {
        if item.isSeparator { return .separator() }
        let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = item.isEnabled
        menuItem.state = item.isChecked ? .on : .off

        // `item.action` is optional, so a bare `.none` here would mean nil rather than the enum's own
        // `none`. Neither of them does anything when chosen, so neither gets a target.
        switch item.action {
        case Optional.none, .some(StatusMenuAction.none):
            break
        case .some(let action):
            menuItem.target = self
            menuItem.action = #selector(choose(_:))
            menuItem.representedObject = ActionBox(action)
        }

        if !item.children.isEmpty {
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            for child in item.children {
                submenu.addItem(makeItem(for: child))
            }
            menuItem.submenu = submenu
        }
        return menuItem
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action)
    }
}
