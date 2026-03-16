from prompt_toolkit.completion import Completer, Completion
from lemon_cli.constants import SLASH_COMMANDS


class SlashCommandCompleter(Completer):
    def get_completions(self, document, complete_event):
        text = document.text_before_cursor.lstrip()
        if not text.startswith("/"):
            return
        word = text.split()[0] if text.split() else text
        for name, desc in SLASH_COMMANDS.items():
            if name.startswith(word):
                yield Completion(
                    name, start_position=-len(word),
                    display=name, display_meta=desc)
