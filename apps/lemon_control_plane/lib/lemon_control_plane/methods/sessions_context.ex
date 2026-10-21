defmodule LemonControlPlane.Methods.SessionsContext do
  @moduledoc """
  Read-only per-category context-window usage of a native session's next
  request: system prompt, tool definitions, skills, context files, memory,
  messages and free space against the model window.

  The runtime measures (see `CodingAgent.Session.ContextUsage`); this handler
  projects counts, bounded labels and enumerated categories only — never prompt
  text, tool arguments, URLs or paths. Category tokens always sum to
  `usedTokens`.
  """
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @categories [
    {:system_prompt, "System prompt"},
    {:tool_definitions, "Tool definitions"},
    {:skills, "Skills"},
    {:context_files, "Context files"},
    {:memory, "Memory"},
    {:user_messages, "User messages"},
    {:assistant_messages, "Assistant messages"},
    {:tool_results, "Tool results"},
    {:summaries, "Summaries"},
    {:unattributed, "System prompt and tools (not itemized)"}
  ]
  @category_labels Map.new(@categories)
  @sources ~w(usage usage+estimate estimate)
  @overhead [:live, :snapshot, :unavailable]
  @top_limit 10
  @label_max 80

  @impl true
  def name, do: "sessions.context"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params) do
      fetch(key, cwd)
    end
  end

  @doc """
  Measure and project one session. Shared by the RPC handler and ACP so both
  surfaces present the same server accounting.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(session_key, cwd) do
    case AgentRuntime.call(:session_context_usage, [session_key, cwd], {:error, :unavailable}) do
      {:ok, usage} when is_map(usage) -> project(session_key, usage)
      {:error, reason} -> NativeSessions.failure(reason)
      _ -> NativeSessions.failure(:unavailable)
    end
  rescue
    _ -> NativeSessions.failure(:unavailable)
  catch
    :exit, _ -> NativeSessions.failure(:unavailable)
  end

  @doc false
  @spec project(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def project(session_key, usage) do
    categories = Enum.flat_map(Map.get(usage, :categories, []), &category/1)
    used = Enum.reduce(categories, 0, &(&1["tokens"] + &2))
    window = positive(Map.get(usage, :window))

    if categories == [] or used != Map.get(usage, :used_tokens) do
      # The runtime guarantees the invariant; a report that breaks it is not shown.
      NativeSessions.failure(:unavailable)
    else
      {:ok,
       %{
         "sessionKey" => session_key,
         "live" => Map.get(usage, :live) == true,
         "overhead" => enum(Map.get(usage, :overhead), @overhead, "unavailable"),
         "model" => model(Map.get(usage, :model)),
         "window" => window,
         "usedTokens" => used,
         "freeTokens" => if(window, do: max(window - used, 0)),
         "percentUsed" => percent(used, window),
         "source" => if(Map.get(usage, :source) in @sources, do: usage.source, else: "estimate"),
         "estimatedTokens" => non_negative(Map.get(usage, :estimated_tokens)),
         "autoCompaction" => auto_compaction(Map.get(usage, :auto_compaction), window),
         "categories" =>
           Enum.map(categories, &Map.put(&1, "percent", percent(&1["tokens"], window))),
         "top" =>
           usage |> Map.get(:top, []) |> Enum.flat_map(&top_item/1) |> Enum.take(@top_limit),
         "messageCount" => non_negative(Map.get(usage, :message_count)),
         "usage" => usage(Map.get(usage, :usage)),
         "measuredAt" => non_negative(Map.get(usage, :measured_at))
       }}
    end
  end

  defp category(%{id: id, tokens: tokens} = category)
       when is_map_key(@category_labels, id) and is_integer(tokens) and tokens >= 0 do
    [
      %{
        "id" => Atom.to_string(id),
        "label" => Map.fetch!(@category_labels, id),
        "tokens" => tokens,
        "items" => non_negative(Map.get(category, :items))
      }
    ]
  end

  defp category(_), do: []

  defp top_item(%{category: category, label: label, tokens: tokens})
       when is_map_key(@category_labels, category) and is_binary(label) and is_integer(tokens) and
              tokens > 0 do
    [%{"category" => Atom.to_string(category), "label" => label(label), "tokens" => tokens}]
  end

  defp top_item(_), do: []

  # Labels are runtime-generated identifiers, but stay bounded and free of
  # control characters and anything path-shaped regardless.
  defp label(label) do
    label =
      label
      |> String.replace(~r/[[:cntrl:]]+/u, " ")
      |> String.trim()
      |> String.slice(0, @label_max)

    if String.contains?(label, ["/", "\\", "://"]), do: "Item", else: label
  end

  defp model(%{provider: provider, id: id}) when is_binary(provider) and is_binary(id) do
    %{"provider" => String.slice(provider, 0, 64), "id" => String.slice(id, 0, 128)}
  end

  defp model(_), do: nil

  defp auto_compaction(%{} = budget, window) when is_integer(window) do
    %{
      "enabled" => Map.get(budget, :enabled) != false,
      "thresholdTokens" => non_negative(Map.get(budget, :threshold_tokens)),
      "reserveTokens" => non_negative(Map.get(budget, :reserve_tokens)),
      "headroomTokens" => non_negative(Map.get(budget, :headroom_tokens))
    }
  end

  defp auto_compaction(_budget, _window), do: nil

  # Provider telemetry remains null when unreported; category estimates above are separate.
  defp usage(%{} = usage) do
    %{
      "tokens" => reported_count(Map.get(usage, :tokens)),
      "costUsd" => cost(Map.get(usage, :cost_usd)),
      "input" => reported_count(Map.get(usage, :input)),
      "output" => reported_count(Map.get(usage, :output)),
      "cacheRead" => reported_count(Map.get(usage, :cache_read)),
      "cacheWrite" => reported_count(Map.get(usage, :cache_write)),
      "assistantMessages" => reported_count(Map.get(usage, :assistant_messages))
    }
  end

  defp usage(_usage), do: nil

  defp cost(value) when is_number(value) and value >= 0, do: value / 1
  defp cost(_), do: nil

  defp reported_count(value) when is_integer(value) and value >= 0, do: value
  defp reported_count(_), do: nil

  defp enum(value, allowed, default),
    do: if(value in allowed, do: Atom.to_string(value), else: default)

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_), do: 0

  defp percent(_tokens, nil), do: nil
  defp percent(tokens, window), do: Float.round(tokens * 100 / window, 1)
end
