import SwiftUI

private struct BotNavigationKey: FocusedValueKey {
    typealias Value = (Int) -> Void
}

public extension FocusedValues {
    var navigateBot: ((Int) -> Void)? {
        get { self[BotNavigationKey.self] }
        set { self[BotNavigationKey.self] = newValue }
    }
}

public struct BotNavigationCommands: Commands {
    @FocusedValue(\.navigateBot) private var navigate
    public init() {}
    public var body: some Commands {
        CommandMenu("Conversation") {
            Button("Previous Bot") { navigate?(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigate == nil)
            Button("Next Bot") { navigate?(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(navigate == nil)
        }
    }
}
