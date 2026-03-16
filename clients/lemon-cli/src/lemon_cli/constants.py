"""Static data: slash commands, spinner frames, tool metadata."""

SLASH_COMMANDS: dict[str, str] = {
    # Session
    "/new": "Start a new session",
    "/reset": "Reset the current session",
    "/clear": "Clear display and reset session",
    "/history": "List saved sessions",
    "/save": "Save the current session",
    "/retry": "Re-send last user message",
    "/undo": "Remove last user/assistant exchange",
    "/rollback": "Rollback to a previous point",
    "/stop": "Abort the running agent",
    # Configuration
    "/model": "Show or switch model (usage: /model [provider:model])",
    "/config": "Show or edit configuration",
    "/skin": "Show or switch theme (usage: /skin [name])",
    "/compact": "Toggle compact display mode",
    "/thinking": "Toggle thinking/reasoning panel",
    # Info
    "/help": "Show available commands",
    "/usage": "Show token usage and cost",
    "/quit": "Exit (also: /exit, /q)",
    # Sessions
    "/sessions": "List saved sessions",
    "/running": "List running sessions",
    "/switch": "Switch active session (usage: /switch <id>)",
    "/close": "Close current or specified session",
    "/resume": "Resume a saved session (usage: /resume <id>)",
}

COMMAND_ALIASES: dict[str, str] = {
    "/exit": "/quit",
    "/q": "/quit",
    "/abort": "/stop",
}

SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

TOOL_EMOJIS: dict[str, str] = {
    "bash": "💻", "terminal": "💻",
    "read": "📖", "read_file": "📖",
    "write": "✍️", "write_file": "✍️",
    "edit": "📝", "edit_file": "📝",
    "grep": "🔍", "search": "🔍",
    "glob": "📂", "find": "📂", "ls": "📂",
    "web_search": "🌐", "websearch": "🌐",
    "web_fetch": "📄", "webfetch": "📄",
    "task": "📋", "todo": "📋",
    "process": "⚙️",
}

TOOL_VERBS: dict[str, str] = {
    "bash": "ran", "terminal": "ran",
    "read": "read", "read_file": "read",
    "write": "wrote", "write_file": "wrote",
    "edit": "edited", "edit_file": "edited",
    "grep": "searched", "search": "searched",
    "glob": "found", "find": "found", "ls": "listed",
    "web_search": "searched", "websearch": "searched",
    "web_fetch": "fetched", "webfetch": "fetched",
    "task": "tasked", "todo": "planned",
    "process": "processed",
}
