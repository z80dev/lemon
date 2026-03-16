from prompt_toolkit.completion import Completer, Completion
from pathlib import Path


class FilePathCompleter(Completer):
    def __init__(self, cwd: str = "."):
        self._cwd = cwd

    def get_completions(self, document, complete_event):
        text = document.text_before_cursor
        # Find the last whitespace-delimited token
        tokens = text.split()
        if not tokens:
            return
        word = tokens[-1]
        if not any(word.startswith(p) for p in ("./", "../", "~/", "/")):
            return
        # Expand and list
        expanded = Path(word).expanduser()
        if not expanded.is_absolute():
            expanded = Path(self._cwd) / expanded
        parent = expanded.parent if not expanded.is_dir() else expanded
        prefix = expanded.name if not expanded.is_dir() else ""
        if not parent.exists():
            return
        count = 0
        for entry in sorted(parent.iterdir()):
            if prefix and not entry.name.startswith(prefix):
                continue
            name = entry.name + ("/" if entry.is_dir() else "")
            yield Completion(name, start_position=-len(prefix),
                           display=name)
            count += 1
            if count >= 30:
                break
