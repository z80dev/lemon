defmodule LemonWeb.Shortcuts do
  @moduledoc """
  Server-side reference of the keyboard shortcuts the web UI registers.

  The bindings themselves live in JavaScript (`priv/static/assets/js/shortcuts.js`
  and the feature hooks that call `Shortcuts.register/2`); this list mirrors
  them so pages such as Settings can render a reference without JavaScript.
  Navigation chords come from `LemonWeb.Nav`, so they cannot drift from the
  rail. Keep the rest in sync when a hook adds or changes a binding.

  `keys` uses the same notation as `LemonWeb.UI.kbd/1`: `+` joins keys pressed
  together, a space separates the keys of a chord (`"g c"`).
  """

  @type shortcut :: %{keys: String.t(), description: String.t()}

  @general [
    %{keys: "mod+k", description: "Open command palette"},
    %{keys: "?", description: "Show keyboard shortcuts"},
    %{keys: "mod+shift+l", description: "Cycle light / dark / system theme"},
    %{keys: "esc", description: "Close dialogs and menus"}
  ]

  @palette [
    %{keys: "up", description: "Previous result"},
    %{keys: "down", description: "Next result"},
    %{keys: "enter", description: "Open result"},
    %{keys: "mod+enter", description: "Open result in split view"},
    %{keys: "tab", description: "Toggle search everywhere (or type /)"}
  ]

  @workspace [
    %{keys: "mod+shift+o", description: "New session"},
    %{keys: "mod+b", description: "Toggle sessions sidebar"},
    %{keys: "mod+i", description: "Toggle inspector"},
    %{keys: "mod+\\", description: "Toggle split view"},
    %{keys: "alt+up", description: "Previous session"},
    %{keys: "alt+down", description: "Next session"}
  ]

  @chat [
    %{keys: "enter", description: "Send message"},
    %{keys: "shift+enter", description: "New line"},
    %{keys: "mod+enter", description: "Send as steer while a run is active"},
    %{keys: "mod+/", description: "Focus composer"},
    %{keys: "esc", description: "Leave composer"},
    %{keys: "mod+.", description: "Stop the active run"},
    %{keys: "shift+tab", description: "Cycle thinking level (in composer)"},
    %{keys: "mod+shift+p", description: "Toggle plan mode"},
    %{keys: "mod+shift+m", description: "Open model picker"},
    %{keys: "alt+o", description: "Expand or collapse all tool output"},
    %{keys: "alt+r", description: "Expand the latest tool or thought"}
  ]

  @doc "Shortcut groups in display order: `[{group, [shortcut]}]`."
  @spec groups() :: [{String.t(), [shortcut()]}]
  def groups do
    [
      {"General", @general},
      {"Navigation", navigation()},
      {"Command palette", @palette},
      {"Workspace", @workspace},
      {"Chat", @chat}
    ]
  end

  @doc "The `g <key>` chords registered for every `LemonWeb.Nav` entry."
  @spec navigation() :: [shortcut()]
  def navigation do
    for %{shortcut: key, label: label} <- LemonWeb.Nav.items(), is_binary(key) do
      %{keys: "g " <> key, description: "Go to #{label}"}
    end
  end
end
