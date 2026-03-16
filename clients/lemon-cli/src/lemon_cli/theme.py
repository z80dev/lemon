"""Theme system: 6 themes with ANSI 256 color values and helpers.

Port of clients/lemon-tui/src/theme.ts.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ThemeColors:
    name: str
    primary: int       # Main brand color
    secondary: int     # Supporting color
    accent: int        # Highlight/emphasis
    success: int       # Green success
    warning: int       # Orange warning
    error: int         # Red error
    muted: int         # Gray muted text
    dim: int           # Dimmer than muted
    border: int        # Panel/box borders
    modeline_bg: int   # Status bar background
    overlay_bg: int    # Overlay background


THEMES: dict[str, ThemeColors] = {
    "lemon": ThemeColors(
        name="lemon",
        primary=220,      # yellow
        secondary=228,    # pale yellow
        accent=208,       # orange
        success=114,      # citrus green
        warning=214,      # orange
        error=203,        # red
        muted=243,        # gray
        dim=241,
        border=240,       # darker gray
        modeline_bg=58,   # dark olive
        overlay_bg=236,   # dark gray
    ),
    "lime": ThemeColors(
        name="lime",
        primary=118,      # bright green
        secondary=157,    # pale green
        accent=154,       # chartreuse
        success=114,      # citrus green
        warning=214,      # orange
        error=203,        # red
        muted=243,        # gray
        dim=241,
        border=240,       # darker gray
        modeline_bg=22,   # dark green
        overlay_bg=22,    # dark green
    ),
    "midnight": ThemeColors(
        name="midnight",
        primary=141,      # soft purple
        secondary=183,    # lavender
        accent=81,        # bright cyan
        success=114,      # green
        warning=221,      # gold
        error=204,        # pink-red
        muted=245,        # cool gray
        dim=243,
        border=60,        # muted purple
        modeline_bg=17,   # deep navy
        overlay_bg=17,    # deep navy
    ),
    "rose": ThemeColors(
        name="rose",
        primary=211,      # soft pink
        secondary=224,    # pale pink
        accent=205,       # hot pink
        success=150,      # soft green
        warning=222,      # warm gold
        error=196,        # bright red
        muted=244,        # warm gray
        dim=242,
        border=132,       # muted rose
        modeline_bg=52,   # dark rose
        overlay_bg=52,    # dark rose
    ),
    "ocean": ThemeColors(
        name="ocean",
        primary=38,       # deep teal
        secondary=116,    # pale aqua
        accent=51,        # bright cyan
        success=114,      # green
        warning=215,      # sandy orange
        error=203,        # coral red
        muted=245,        # blue-gray
        dim=243,
        border=30,        # muted teal
        modeline_bg=23,   # deep ocean
        overlay_bg=23,    # deep ocean
    ),
    "contrast": ThemeColors(
        name="contrast",
        primary=15,       # bright white
        secondary=14,     # bright cyan
        accent=11,        # bright yellow
        success=10,       # bright green
        warning=11,       # bright yellow
        error=9,          # bright red
        muted=250,        # light gray
        dim=248,
        border=248,       # light gray
        modeline_bg=234,  # very dark
        overlay_bg=234,   # very dark
    ),
}

# ---------------------------------------------------------------------------
# Lemon ASCII art
# ---------------------------------------------------------------------------

LEMON_ART = """\
       {g}▄██▄{r}
      {g}▄████▄{r}
     {p}████████{r}
    {p}██{a} ◠   ◠ {p}██{r}
    {p}██{a}  ‿   {p}██{r}
     {p}████████{r}
      {p}▀████▀{r}
"""
# {g} = success color (green), {p} = primary color (yellow),
# {a} = accent (orange), {r} = reset

# ---------------------------------------------------------------------------
# Module-level current theme state
# ---------------------------------------------------------------------------

_current_theme: ThemeColors = THEMES["lemon"]


def get_theme(name: str) -> ThemeColors | None:
    """Return a theme by name, or None if not found."""
    return THEMES.get(name)


def set_theme(name: str) -> bool:
    """Set the active theme. Returns True on success."""
    global _current_theme
    if name in THEMES:
        _current_theme = THEMES[name]
        return True
    return False


def get_current_theme() -> ThemeColors:
    """Return the currently active theme."""
    return _current_theme


def get_available_themes() -> list[str]:
    """Return list of all available theme names."""
    return list(THEMES.keys())


# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------

def ansi256(color_num: int) -> str:
    """Return ANSI escape sequence for 256-color foreground."""
    return f"\033[38;5;{color_num}m"


def ansi256_bg(color_num: int) -> str:
    """Return ANSI escape sequence for 256-color background."""
    return f"\033[48;5;{color_num}m"


ANSI_RESET = "\033[0m"


def rich_color(color_num: int) -> str:
    """Return Rich markup color string for 256-color."""
    return f"color({color_num})"


# ---------------------------------------------------------------------------
# ANSI 256 index -> hex conversion (for prompt_toolkit styles)
# ---------------------------------------------------------------------------

_ANSI_STANDARD_16 = [
    "#000000", "#800000", "#008000", "#808000", "#000080", "#800080", "#008080", "#c0c0c0",
    "#808080", "#ff0000", "#00ff00", "#ffff00", "#0000ff", "#ff00ff", "#00ffff", "#ffffff",
]
_CUBE_VALUES = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]


def ansi256_to_hex(n: int) -> str:
    """Convert ANSI 256-color index to #rrggbb hex string."""
    if n < 16:
        return _ANSI_STANDARD_16[n]
    if n < 232:
        n -= 16
        r = _CUBE_VALUES[n // 36]
        g = _CUBE_VALUES[(n % 36) // 6]
        b = _CUBE_VALUES[n % 6]
        return f"#{r:02x}{g:02x}{b:02x}"
    # Grayscale 232-255
    level = 8 + 10 * (n - 232)
    return f"#{level:02x}{level:02x}{level:02x}"


def _fg(color_num: int) -> str:
    return f"fg:{ansi256_to_hex(color_num)}"


def _bg(color_num: int) -> str:
    return f"bg:{ansi256_to_hex(color_num)}"


# ---------------------------------------------------------------------------
# prompt_toolkit style builder
# ---------------------------------------------------------------------------

def build_pt_style(theme: ThemeColors) -> dict[str, str]:
    """Build prompt_toolkit Style.from_dict() overrides for the given theme."""
    return {
        "input-area": _fg(theme.primary),
        "placeholder": f"{_fg(theme.muted)} italic",
        "prompt": _fg(theme.primary),
        "input-rule": _fg(theme.border),
        "completion-menu": f"bg:#1a1a2e {_fg(theme.muted)}",
        "completion-menu.completion": f"bg:#1a1a2e {_fg(theme.muted)}",
        "completion-menu.completion.current": f"bg:#333355 {_fg(theme.primary)}",
        "completion-menu.meta.completion": f"bg:#1a1a2e {_fg(theme.dim)}",
        "completion-menu.meta.completion.current": f"bg:#333355 {_fg(theme.accent)}",
        "status-bar": f"{_bg(theme.modeline_bg)} {_fg(theme.muted)}",
        "status-bar.model": _fg(theme.secondary),
        "status-bar.busy": _fg(theme.primary),
        "overlay": _bg(theme.overlay_bg),
        "overlay.title": f"{_fg(theme.primary)} bold",
        "overlay.border": _fg(theme.border),
    }


# ---------------------------------------------------------------------------
# ASCII art renderer
# ---------------------------------------------------------------------------

def get_lemon_art(theme: ThemeColors | None = None) -> str:
    """Return themed lemon ASCII art with ANSI color codes."""
    t = theme or _current_theme
    return LEMON_ART.format(
        g=ansi256(t.success),
        p=ansi256(t.primary),
        a=ansi256(t.accent),
        r=ANSI_RESET,
    )
