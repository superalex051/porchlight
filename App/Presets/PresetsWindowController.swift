import ADModel
import ADUI
import AppKit
import SwiftUI

/// Hosts the presets window. The model holds the edits, so closing the window keeps unsaved ones, and
/// opening it again with none reads the files again. As the window's delegate it also gets File > Save
/// from the main menu.
@MainActor
final class PresetsWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    private let model: PresetsEditorModel
    private var window: NSWindow?

    init(library: any PresetLibrary) {
        model = PresetsEditorModel(library: library)
        super.init()
    }

    /// Porch Light has no Dock icon and is never the active app on its own, so it's brought forward with
    /// the window. Choosing the menu item again only brings the window forward.
    func show() {
        let window = window ?? makeWindow()
        if !window.isVisible { model.reloadIfUnchanged() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Command-S, from the main menu. The Save button has the same shortcut, and whichever AppKit asks
    /// first saves: the model saves only when there's something to save.
    @objc func saveDocument(_ sender: Any?) {
        model.save()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(saveDocument(_:)) ? model.canSave : true
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PresetsEditorView(model: model)))
        window.title = "Presets"
        // Kept when closed, so it opens again where it was.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}
