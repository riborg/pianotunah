import SwiftUI

/// The Help menu: *Piano Tunah Help* in place of the default item, opening
/// the help window (``HelpView``).
struct HelpCommands: Commands {
    static let windowID = "help"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                openWindow(id: Self.windowID)
            } label: {
                Text("Piano Tunah Help", tableName: "AppSettings", comment: "Help menu item; also the help window's title.")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
