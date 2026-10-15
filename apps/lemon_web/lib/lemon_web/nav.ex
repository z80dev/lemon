defmodule LemonWeb.Nav do
  @moduledoc """
  The web UI's information architecture: one entry per top-level page.

  The rail, the mobile drawer and the command palette all render from this
  list. LiveViews set `socket.assigns.nav` to an item `id` to mark the active
  entry. `shortcut` is the second key of the `g <key>` navigation chord.
  """

  @type item :: %{
          id: atom(),
          label: String.t(),
          path: String.t(),
          icon: String.t(),
          group: String.t(),
          shortcut: String.t() | nil,
          keywords: String.t()
        }

  @items [
    %{
      id: :chat,
      label: "Chat",
      path: "/",
      icon: "message-square",
      group: "Workspace",
      shortcut: "c",
      keywords: "new session conversation agent prompt"
    },
    %{
      id: :sessions,
      label: "Sessions",
      path: "/sessions",
      icon: "list",
      group: "Workspace",
      shortcut: "s",
      keywords: "history archive fork rename export prune search"
    },
    %{
      id: :omp,
      label: "omp",
      path: "/omp",
      icon: "terminal",
      group: "Workspace",
      shortcut: "o",
      keywords: "oh-my-pi delegate external agent sessions steer"
    },
    %{
      id: :automation,
      label: "Automation",
      path: "/automation",
      icon: "zap",
      group: "Automate",
      shortcut: "a",
      keywords: "cron schedule goals kanban board jobs"
    },
    %{
      id: :blueprints,
      label: "Blueprints",
      path: "/blueprints",
      icon: "layers",
      group: "Automate",
      shortcut: "b",
      keywords: "bundles templates activate catalog"
    },
    %{
      id: :skills,
      label: "Skills",
      path: "/skills",
      icon: "sparkles",
      group: "Knowledge",
      shortcut: "k",
      keywords: "install catalog hermes abilities"
    },
    %{
      id: :memory,
      label: "Memory",
      path: "/memory",
      icon: "brain",
      group: "Knowledge",
      shortcut: "y",
      keywords: "recall remember notes documents"
    },
    %{
      id: :learning,
      label: "Learning",
      path: "/learning",
      icon: "sparkles",
      group: "Knowledge",
      shortcut: "l",
      keywords: "journey timeline learned memory skills"
    },
    %{
      id: :mcp,
      label: "MCP",
      path: "/mcp",
      icon: "plug",
      group: "Knowledge",
      shortcut: "p",
      keywords: "model context protocol servers connections tools"
    },
    %{
      id: :models,
      label: "Models",
      path: "/models",
      icon: "cpu",
      group: "Runtime",
      shortcut: "m",
      keywords: "providers credentials api keys default model"
    },
    %{
      id: :profiles,
      label: "Profiles",
      path: "/profiles",
      icon: "users",
      group: "Runtime",
      shortcut: "f",
      keywords: "personas agents roster"
    },
    %{
      id: :nodes,
      label: "Nodes",
      path: "/nodes",
      icon: "server",
      group: "Runtime",
      shortcut: "n",
      keywords: "execution nodes pairing remote workers"
    },
    %{
      id: :usage,
      label: "Usage",
      path: "/usage",
      icon: "bar-chart",
      group: "Runtime",
      shortcut: "u",
      keywords: "cost tokens spend billing"
    },
    %{
      id: :diagnostics,
      label: "Diagnostics",
      path: "/diagnostics",
      icon: "stethoscope",
      group: "Runtime",
      shortcut: "d",
      keywords: "doctor health status logs"
    },
    %{
      id: :settings,
      label: "Settings",
      path: "/settings",
      icon: "settings",
      group: "System",
      shortcut: ",",
      keywords: "preferences theme config shortcuts"
    }
  ]

  @doc "All navigation entries in display order."
  @spec items() :: [item()]
  def items, do: @items

  @doc "Entries grouped for the rail, preserving order."
  @spec groups() :: [{String.t(), [item()]}]
  def groups do
    @items
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [first | _] = items -> {first.group, items} end)
  end

  @doc "Looks up one entry."
  @spec fetch(atom()) :: {:ok, item()} | :error
  def fetch(id),
    do: Enum.find(@items, &(&1.id == id)) |> then(&if(&1, do: {:ok, &1}, else: :error))
end
