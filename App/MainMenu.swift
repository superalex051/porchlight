import AppKit

/// The menu bar Porch Light never shows. An accessory app has none on screen, but AppKit still finds key
/// equivalents in it, so without it Command-Z, X, C, V, A, W and S would do nothing in the presets
/// window. There's no Quit here, because quitting ends a session: Quit stays in the status menu.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        // The first item is the app menu. It stays empty, so File and Edit sit where AppKit expects them.
        menu.addItem(submenu("Porch Light", []))
        menu.addItem(submenu("File", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Save", action: #selector(PresetsWindowController.saveDocument(_:)), keyEquivalent: "s"),
        ]))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for child in items {
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }
}
