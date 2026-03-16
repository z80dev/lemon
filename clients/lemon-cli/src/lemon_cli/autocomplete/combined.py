from prompt_toolkit.completion import Completer
from lemon_cli.autocomplete.slash import SlashCommandCompleter
from lemon_cli.autocomplete.filepath import FilePathCompleter


class CombinedCompleter(Completer):
    def __init__(self, cwd: str = "."):
        self._slash = SlashCommandCompleter()
        self._filepath = FilePathCompleter(cwd)

    def get_completions(self, document, complete_event):
        text = document.text_before_cursor.lstrip()
        if text.startswith("/"):
            yield from self._slash.get_completions(document, complete_event)
        else:
            yield from self._filepath.get_completions(document, complete_event)
