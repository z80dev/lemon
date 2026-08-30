defmodule LemonChannels.CommandCatalog do
  @moduledoc """
  Portable presentation metadata for Lemon's shared slash-command surface.

  The catalog deliberately does not dispatch commands. Channel adapters and
  interactive clients may use it for help, completion, and capability routing,
  while the router, session runtime, and control plane continue to own command
  semantics. Capability ids describe the Lemon action a surface must implement;
  they are not control-plane method names.
  """

  @commands [
    %{
      "name" => "queue",
      "command" => "/queue",
      "aliases" => ["/q"],
      "description" =>
        "Queue a prompt as a later Lemon turn without interrupting the active run.",
      "category" => "session",
      "arguments" => "<prompt>",
      "argumentMode" => "text",
      "busyPolicy" => "queue",
      "readOnly" => false,
      "capabilities" => ["conversation.queue"]
    },
    %{
      "name" => "steer",
      "command" => "/steer",
      "aliases" => [],
      "description" =>
        "Steer the active Lemon run without creating a separate conversation turn.",
      "category" => "session",
      "arguments" => "<prompt>",
      "argumentMode" => "text",
      "busyPolicy" => "steer",
      "readOnly" => false,
      "capabilities" => ["conversation.steer"]
    },
    %{
      "name" => "reset",
      "command" => "/reset",
      "aliases" => ["/new"],
      "description" => "Start a fresh Lemon session for the current conversation.",
      "category" => "session",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "cancel_then_dispatch",
      "readOnly" => false,
      "capabilities" => ["session.reset"]
    },
    %{
      "name" => "reasoning",
      "command" => "/reasoning",
      "aliases" => ["/thinking"],
      "description" =>
        "Show or change the session reasoning effort using Lemon's thinking policy.",
      "category" => "configuration",
      "arguments" => "[level|clear|status]",
      "argumentMode" => "options",
      "busyPolicy" => "dispatch",
      "readOnly" => false,
      "capabilities" => ["session.reasoning"]
    },
    %{
      "name" => "stop",
      "command" => "/stop",
      "aliases" => ["/cancel"],
      "description" =>
        "Cancel the active Lemon run for this conversation without a process-wide kill.",
      "category" => "session",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "cancel",
      "readOnly" => false,
      "capabilities" => ["conversation.cancel"]
    },
    %{
      "name" => "status",
      "command" => "/status",
      "aliases" => [],
      "description" => "Show the current Lemon session and run status.",
      "category" => "information",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "dispatch",
      "readOnly" => true,
      "capabilities" => ["session.status"]
    },
    %{
      "name" => "usage",
      "command" => "/usage",
      "aliases" => [],
      "description" => "Show the token and cost usage available from Lemon diagnostics.",
      "category" => "information",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "dispatch",
      "readOnly" => true,
      "capabilities" => ["session.usage"]
    },
    %{
      "name" => "agents",
      "command" => "/agents",
      "aliases" => ["/tasks"],
      "description" => "Show active native Lemon agents and delegated tasks.",
      "category" => "information",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "dispatch",
      "readOnly" => true,
      "capabilities" => ["session.tasks"]
    },
    %{
      "name" => "compress",
      "command" => "/compress",
      "aliases" => ["/compact"],
      "description" => "Request compaction of the current Lemon session context.",
      "category" => "session",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "reject",
      "readOnly" => false,
      "capabilities" => ["session.compact"]
    },
    %{
      "name" => "commands",
      "command" => "/commands",
      "aliases" => [],
      "description" => "Browse the portable Lemon command catalog.",
      "category" => "information",
      "arguments" => "",
      "argumentMode" => "none",
      "busyPolicy" => "dispatch",
      "readOnly" => true,
      "capabilities" => ["commands.catalog"]
    },
    %{
      "name" => "help",
      "command" => "/help",
      "aliases" => [],
      "description" => "Show grouped help generated from the Lemon command catalog.",
      "category" => "information",
      "arguments" => "[filter]",
      "argumentMode" => "text",
      "busyPolicy" => "dispatch",
      "readOnly" => true,
      "capabilities" => ["commands.catalog"]
    },
    %{
      "name" => "bg",
      "command" => "/bg",
      "aliases" => [],
      "description" =>
        "Start or inspect an independent background Lemon session while this session stays available.",
      "category" => "session",
      "arguments" => "<prompt> | list | status <id> | result <id> | cancel <id>",
      "argumentMode" => "text",
      "busyPolicy" => "dispatch",
      "readOnly" => false,
      "capabilities" => ["session.background"]
    },
    %{
      "name" => "btw",
      "command" => "/btw",
      "aliases" => [],
      "description" =>
        "Ask a side question from a read-only conversation snapshot without adding a turn.",
      "category" => "session",
      "arguments" => "<question>",
      "argumentMode" => "text",
      "busyPolicy" => "dispatch",
      "readOnly" => false,
      "capabilities" => ["session.side_question"]
    }
  ]

  @lookup Enum.reduce(@commands, %{}, fn command, lookup ->
            [command["command"] | command["aliases"]]
            |> Enum.reduce(lookup, fn name, acc ->
              Map.put(acc, name |> String.trim_leading("/") |> String.downcase(), command)
            end)
          end)

  @doc "Returns the ordered, JSON-safe command definitions."
  @spec catalog() :: [map()]
  def catalog, do: @commands

  @doc "Returns one command definition for a canonical name or alias."
  @spec find(String.t()) :: {:ok, map()} | :error
  def find(value) when is_binary(value) do
    case Map.fetch(@lookup, normalize(value)) do
      {:ok, command} -> {:ok, command}
      :error -> :error
    end
  end

  def find(_value), do: :error

  @doc "Returns category counts in deterministic presentation order."
  @spec categories() :: [map()]
  def categories do
    @commands
    |> Enum.frequencies_by(& &1["category"])
    |> Enum.map(fn {category, count} -> %{"category" => category, "count" => count} end)
    |> Enum.sort_by(& &1["category"])
  end

  @doc "Returns bounded catalog metadata for discovery responses."
  @spec summary() :: map()
  def summary do
    aliases = Enum.sum(Enum.map(@commands, &length(&1["aliases"])))

    capabilities =
      @commands
      |> Enum.flat_map(& &1["capabilities"])
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "version" => 1,
      "dynamic" => false,
      "count" => length(@commands),
      "aliasCount" => aliases,
      "capabilities" => capabilities
    }
  end

  defp normalize(value) do
    case value |> String.trim() |> String.split(~r/\s+/, parts: 2, trim: true) do
      [token | _] -> token |> String.trim_leading("/") |> String.downcase()
      [] -> ""
    end
  end
end
