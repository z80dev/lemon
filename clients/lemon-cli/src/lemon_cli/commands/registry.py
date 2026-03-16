from dataclasses import dataclass, field
from typing import Callable
from lemon_cli.constants import SLASH_COMMANDS, COMMAND_ALIASES


@dataclass
class SlashCommand:
    name: str
    aliases: list[str]
    description: str
    handler: Callable  # fn(args: list[str]) -> bool (True=continue, False=quit)


class CommandRegistry:
    def __init__(self):
        self._commands: dict[str, SlashCommand] = {}

    def register(self, cmd: SlashCommand):
        self._commands[cmd.name] = cmd
        for alias in cmd.aliases:
            self._commands[alias] = cmd

    def dispatch(self, text: str) -> bool:
        """Parse and dispatch. Returns False to quit."""
        parts = text.strip().split(maxsplit=1)
        cmd_name = parts[0].lower()
        args = parts[1].split() if len(parts) > 1 else []

        # Resolve alias
        cmd_name = COMMAND_ALIASES.get(cmd_name, cmd_name)

        cmd = self._commands.get(cmd_name)
        if cmd:
            return cmd.handler(args)

        # Prefix matching
        matches = [name for name in self._commands if name.startswith(cmd_name)]
        if len(matches) == 1:
            return self._commands[matches[0]].handler(args)
        elif len(matches) > 1:
            from lemon_cli.display.console import cprint
            cprint(f"Ambiguous command. Did you mean: {', '.join(sorted(matches))}?")
            return True

        from lemon_cli.display.console import cprint
        cprint(f"Unknown command: {cmd_name}. Type /help for available commands.")
        return True

    def get_command_names(self) -> list[str]:
        return [name for name in self._commands if name.startswith("/")]

    def get_commands_with_descriptions(self) -> list[tuple[str, str]]:
        seen = set()
        result = []
        for name, cmd in self._commands.items():
            if cmd.name not in seen and name.startswith("/"):
                seen.add(cmd.name)
                result.append((cmd.name, cmd.description))
        return sorted(result)


def build_command_registry(app) -> CommandRegistry:
    """Build and return a fully-populated CommandRegistry."""
    from lemon_cli.commands.core import register_core_commands
    from lemon_cli.commands.session import register_session_commands
    from lemon_cli.commands.ui import register_ui_commands

    registry = CommandRegistry()
    register_core_commands(registry, app)
    register_session_commands(registry, app)
    register_ui_commands(registry, app)
    return registry
