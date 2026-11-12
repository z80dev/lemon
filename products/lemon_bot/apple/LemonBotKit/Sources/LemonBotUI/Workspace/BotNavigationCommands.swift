import SwiftUI

public extension Notification.Name {
    /// Posted by **Previous Bot**/**Next Bot**; `object` is the `Int` offset. The workspace handles it.
    static let lemonBotNavigateBot = Notification.Name("LemonBot.navigateBot")
}

/// macOS menu commands for stepping through Bots. They post instead of reading a focused value:
/// SwiftUI only refreshes command state when a menu opens, so a focus-gated item stayed disabled
/// and ⌘[ / ⌘] did nothing after launch until the user had opened the menu bar once.
public struct BotNavigationCommands: Commands {
    public init() {}
    public var body: some Commands {
        CommandMenu("Conversation") {
            Button("Previous Bot") { NotificationCenter.default.post(name: .lemonBotNavigateBot, object: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Bot") { NotificationCenter.default.post(name: .lemonBotNavigateBot, object: 1) }
                .keyboardShortcut("]", modifiers: .command)
        }
    }
}
