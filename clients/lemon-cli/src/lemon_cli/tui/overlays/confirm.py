from lemon_cli.tui.overlays.base import OverlayBase


class ConfirmOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 60.0):
        super().__init__(timeout)
        self.title = params.get("title", "Confirm")
        self.message = params.get("message", "")

    def render(self) -> str:
        return f"  {self.title}\n  {self.message}\n  [Y/n] "

    def confirm(self, yes: bool = True):
        self.submit(yes)
