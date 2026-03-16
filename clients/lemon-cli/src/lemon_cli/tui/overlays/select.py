from lemon_cli.tui.overlays.base import OverlayBase


class SelectOverlay(OverlayBase):
    """Numbered list selection for ui_request method=select."""

    def __init__(self, params: dict, timeout: float = 120.0):
        super().__init__(timeout)
        self.title = params.get("title", "Select an option")
        self.options = params.get("options", [])
        self.selected_index = 0

    def render(self) -> str:
        lines = [f"  {self.title}\n"]
        for i, opt in enumerate(self.options):
            marker = ">" if i == self.selected_index else " "
            label = opt.get("label", f"Option {i+1}")
            desc = opt.get("description", "")
            desc_str = f" - {desc}" if desc else ""
            lines.append(f"  {marker} [{i+1}] {label}{desc_str}")
        lines.append(f"\n  Enter number or use arrows, Enter to confirm")
        return "\n".join(lines)

    def move_up(self):
        self.selected_index = max(0, self.selected_index - 1)

    def move_down(self):
        self.selected_index = min(len(self.options) - 1, self.selected_index + 1)

    def confirm(self):
        if self.options:
            self.submit(self.options[self.selected_index].get("value"))
