import os
import tempfile
import subprocess
from lemon_cli.tui.overlays.base import OverlayBase


class EditorOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 300.0):
        super().__init__(timeout)
        self.title = params.get("title", "Edit")
        self.prefill = params.get("prefill", "")

    def launch(self):
        """Launch $EDITOR with prefill content."""
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "nano"
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            if self.prefill:
                f.write(self.prefill)
            f.flush()
            tmp_path = f.name

        try:
            subprocess.run([editor, tmp_path], check=True)
            with open(tmp_path) as f:
                result = f.read()
            self.submit(result)
        except Exception:
            self.submit(None)
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
