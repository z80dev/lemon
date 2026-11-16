defmodule LemonControlPlane.ACP.ContextReport do
  @moduledoc """
  Renders a projected `sessions.context` breakdown for ACP clients: a Markdown
  agent message (usage bar, per-category table, largest contributors, estimate
  caveats) and the matching standard `usage_update`. Input is the bounded wire
  map from `LemonControlPlane.Methods.SessionsContext`, so nothing here can
  reach prompt text or paths.
  """

  @bar_cells 40

  @doc "Markdown body for the `/context` command."
  @spec markdown(map()) :: String.t()
  def markdown(report) do
    [
      header(report),
      bar(report),
      table(report),
      compaction(report["autoCompaction"]),
      get_in(report, ["promptCache", "explanation"]),
      top(report["top"]),
      caveat(report)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  @doc """
  The standard ACP `usage_update` for the measured context, with the full
  breakdown under `_meta.lemon.context`; `nil` when the window is unknown.
  """
  @spec usage_update(map()) :: map() | nil
  def usage_update(%{"window" => window, "usedTokens" => used} = report)
      when is_integer(window) and window > 0 do
    %{
      "sessionUpdate" => "usage_update",
      "size" => window,
      "used" => used,
      "_meta" => %{"lemon" => %{"context" => report}}
    }
  end

  def usage_update(_report), do: nil

  defp header(report) do
    model = get_in(report, ["model", "id"])

    total =
      case report["window"] do
        nil ->
          "#{tokens(report["usedTokens"])} tokens (window unknown)"

        window ->
          "#{tokens(report["usedTokens"])} / #{tokens(window)} tokens (#{report["percentUsed"]}%)"
      end

    ["**Context usage**", model && "`#{model}`", total, source(report["source"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp source("usage"), do: "provider-reported"
  defp source("usage+estimate"), do: "reported + estimated"
  defp source(_), do: "estimated"

  defp bar(%{"window" => window, "usedTokens" => used}) when is_integer(window) do
    filled = min(round(used * @bar_cells / window), @bar_cells)
    "`" <> String.duplicate("█", filled) <> String.duplicate("░", @bar_cells - filled) <> "`"
  end

  defp bar(_report), do: nil

  defp table(report) do
    rows =
      report["categories"]
      |> Enum.reject(&(&1["tokens"] == 0))
      |> Enum.map(&row(&1["label"], &1["tokens"], &1["percent"]))

    free =
      if report["freeTokens"],
        do: [
          row("Free space", report["freeTokens"], percent(report["freeTokens"], report["window"]))
        ],
        else: []

    Enum.join(
      ["| Category | Tokens | % of window |", "| --- | ---: | ---: |" | rows ++ free],
      "\n"
    )
  end

  defp row(label, count, percent),
    do: "| #{label} | #{tokens(count)} | #{if percent, do: "#{percent}%", else: "—"} |"

  defp compaction(%{"enabled" => true} = budget),
    do:
      "Auto-compaction at #{tokens(budget["thresholdTokens"])} tokens " <>
        "(#{tokens(budget["headroomTokens"])} headroom)."

  defp compaction(%{"enabled" => false}), do: "Auto-compaction is disabled."
  defp compaction(_), do: nil

  defp top([]), do: nil

  defp top(items) do
    lines =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {item, index} ->
        "#{index}. #{item["label"]} — #{tokens(item["tokens"])}"
      end)

    Enum.join(["**Largest contributors**" | lines], "\n")
  end

  defp caveat(report) do
    split =
      if report["source"] == "estimate",
        do: "Counts are estimates (≈4 characters per token).",
        else:
          "Category splits are estimates (≈4 characters per token) scaled to the provider-reported total."

    overhead =
      case report["overhead"] do
        "snapshot" -> " System prompt and tools were measured when the last turn ended."
        "unavailable" -> " System prompt and tools are not itemized for this session yet."
        _ -> ""
      end

    "_" <> split <> overhead <> "_"
  end

  defp percent(_count, nil), do: nil
  defp percent(count, window), do: Float.round(count * 100 / window, 1)

  defp tokens(count) when is_integer(count) and count >= 1_000_000,
    do: "#{Float.round(count / 1_000_000, 1)}M"

  defp tokens(count) when is_integer(count) and count >= 1_000,
    do: "#{Float.round(count / 1_000, 1)}k"

  defp tokens(count), do: "#{count}"
end
