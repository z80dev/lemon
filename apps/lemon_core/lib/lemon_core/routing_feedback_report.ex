defmodule LemonCore.RoutingFeedbackReport do
  @moduledoc """
  Offline evaluation and reporting layer for routing feedback.

  Provides filtering, confidence annotation, and formatting of routing
  feedback data. Keeps offline eval logic separate from online routing.

  ## Confidence levels

  Confidence is assigned based on sample size and success rate:

  | Level          | Criteria                                          |
  |----------------|---------------------------------------------------|
  | `:insufficient`| `total < min_sample_size`                         |
  | `:low`         | `total >= min_sample_size` and `success_rate < 0.5`|
  | `:medium`      | `success_rate >= 0.5` and `< 0.8`                 |
  | `:high`        | `success_rate >= 0.8`                             |

  ## Minimum sample size

  The `min_sample_size` threshold is read from `RoutingFeedbackStore.min_sample_size/0`
  (default 5, configurable via application config). Confidence is `:insufficient`
  until this threshold is met.

  ## Recency

  Each entry is annotated with `last_seen_ms`. Pass `since_ms:` to filter
  entries whose most-recent sample predates the cutoff.

  ## Usage

      # All fingerprints with confidence annotation
      {:ok, entries} = RoutingFeedbackReport.list_all()

      # Filter by workspace
      {:ok, entries} = RoutingFeedbackReport.by_workspace("/my/project")

      # Filter by task family (last 7 days only)
      since = System.system_time(:millisecond) - 7 * 24 * 3600_000
      {:ok, entries} = RoutingFeedbackReport.by_family(:code, since_ms: since)

      # Human-readable output
      IO.puts(RoutingFeedbackReport.format(entries))
  """

  alias LemonCore.RoutingFeedbackStore

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  List all fingerprints with confidence annotations.

  ## Options

  - `:since_ms` — exclude entries whose `last_seen_ms` is older than this
    Unix millisecond timestamp.
  """
  @spec list_all(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(opts \\ []) do
    case RoutingFeedbackStore.list_fingerprints() do
      {:ok, rows} ->
        entries = rows |> filter_since(opts) |> Enum.map(&annotate_confidence/1)
        {:ok, entries}

      err ->
        err
    end
  end

  @doc """
  Filter entries by workspace key.

  The workspace is the third `|`-delimited segment in the fingerprint key.
  Pass `"-"` to match runs with no workspace.
  """
  @spec by_workspace(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def by_workspace(workspace, opts \\ []) when is_binary(workspace) do
    case list_all(opts) do
      {:ok, rows} ->
        {:ok, Enum.filter(rows, fn row -> parse_key(row.fingerprint_key).workspace == workspace end)}

      err ->
        err
    end
  end

  @doc """
  Filter entries by task family.

  The family is the first `|`-delimited segment in the fingerprint key.
  Accepts an atom (`:code`) or string (`"code"`).
  """
  @spec by_family(String.t() | atom(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def by_family(family, opts \\ []) do
    family_str = to_string(family)

    case list_all(opts) do
      {:ok, rows} ->
        {:ok, Enum.filter(rows, fn row -> parse_key(row.fingerprint_key).family == family_str end)}

      err ->
        err
    end
  end

  @doc """
  Parse a fingerprint key string into a map of components.

  Key format: `family|toolset|workspace|provider|model`

  Each segment that equals `"-"` is returned as `nil`.

  ## Examples

      iex> RoutingFeedbackReport.parse_key("code|bash|/my/proj|anthropic|opus")
      %{family: "code", toolset: "bash", workspace: "/my/proj", provider: "anthropic", model: "opus"}

      iex> RoutingFeedbackReport.parse_key("query|-|-|-|-")
      %{family: "query", toolset: nil, workspace: nil, provider: nil, model: nil}
  """
  @spec parse_key(String.t()) :: map()
  def parse_key(key) when is_binary(key) do
    [family, toolset, workspace, provider, model] =
      key
      |> String.split("|", parts: 5)
      |> Enum.take(5)
      |> then(fn parts -> parts ++ List.duplicate("-", max(0, 5 - length(parts))) end)

    %{
      family: nil_if_dash(family),
      toolset: nil_if_dash(toolset),
      workspace: nil_if_dash(workspace),
      provider: nil_if_dash(provider),
      model: nil_if_dash(model)
    }
  end

  @doc """
  Format a list of annotated fingerprint entries for human-readable output.

  Returns a multi-line string suitable for `Mix.shell().info/1`.
  """
  @spec format([map()]) :: String.t()
  def format([]) do
    "No routing feedback data found."
  end

  def format(entries) do
    entries
    |> Enum.map(&format_entry/1)
    |> Enum.join("\n\n")
  end

  # ── Private helpers ────────────────────────────────────────────────────────────

  defp annotate_confidence(%{total: total, success_count: success_count} = row) do
    min_n = RoutingFeedbackStore.min_sample_size()
    success_rate = if total > 0, do: success_count / total, else: 0.0

    confidence =
      cond do
        total < min_n -> :insufficient
        success_rate >= 0.8 -> :high
        success_rate >= 0.5 -> :medium
        true -> :low
      end

    row
    |> Map.put(:success_rate, Float.round(success_rate, 4))
    |> Map.put(:confidence, confidence)
  end

  defp filter_since(rows, opts) do
    case Keyword.get(opts, :since_ms) do
      nil -> rows
      since_ms -> Enum.filter(rows, fn row -> (row.last_seen_ms || 0) >= since_ms end)
    end
  end

  defp format_entry(%{fingerprint_key: key} = entry) do
    parsed = parse_key(key)
    confidence_label = confidence_badge(entry.confidence)
    rate_pct = Float.round((entry.success_rate || 0.0) * 100, 1)
    dur_str = if entry.avg_duration_ms, do: "#{entry.avg_duration_ms}ms avg", else: "no duration"

    family = parsed.family || "-"
    workspace = parsed.workspace || "(global)"
    model = parsed.model || "-"

    "#{key} [#{confidence_label}]\n" <>
      "  family=#{family}  workspace=#{workspace}  model=#{model}\n" <>
      "  samples=#{entry.total}  success_rate=#{rate_pct}%  #{dur_str}"
  end

  defp confidence_badge(:high), do: "HIGH"
  defp confidence_badge(:medium), do: "MEDIUM"
  defp confidence_badge(:low), do: "LOW"
  defp confidence_badge(:insufficient), do: "INSUFFICIENT (<min_sample_size)"

  defp nil_if_dash("-"), do: nil
  defp nil_if_dash(v), do: v
end
