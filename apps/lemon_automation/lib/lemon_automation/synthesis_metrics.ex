defmodule LemonAutomation.SynthesisMetrics do
  @moduledoc """
  Durable metric rows for scheduled skill-synthesis passes.

  `LemonAutomation.SynthesisRunner` records one row per pass that examined at
  least one candidate. The rows accumulate the evidence
  `LemonRouter.RolloutGate.evaluate_synthesis/1` needs before
  `skill_synthesis_drafts` can graduate from `"opt-in"` to `"default-on"` —
  the gate itself is pure and keeps no store, so this module is that store.

  Rows live in the `:synthesis_metrics` table of `LemonCore.Store` and are
  pruned to the newest 500 entries on every write.

  ## Gate semantics

  `aggregate/0` feeds the gate `generated: kept + blocked` — every draft the
  generator actually produced, whether or not the audit engine later deleted
  it — and `blocked_by_audit: blocked`. That matches the gate's documented
  meaning of the false-positive rate ("fraction of *generated* drafts blocked
  by audit"). Rows store `generated` (kept) and `blocked_by_audit` separately,
  so a stricter reading only changes this function.
  """

  alias LemonCore.Store
  alias LemonRouter.RolloutGate

  @table :synthesis_metrics
  @max_rows 500
  @default_limit 500

  @type row :: %{
          id: String.t(),
          ts_ms: integer(),
          agent_id: String.t(),
          total_candidates: non_neg_integer(),
          generated: non_neg_integer(),
          blocked_by_audit: non_neg_integer(),
          skipped_other: non_neg_integer(),
          latest_doc_ms: integer() | nil,
          gate: String.t()
        }

  @type aggregate :: %{
          total_candidates: non_neg_integer(),
          generated: non_neg_integer(),
          blocked_by_audit: non_neg_integer()
        }

  @doc """
  Record one synthesis pass and return the stored row.

  `run_result` is the map returned by `LemonSkills.Synthesis.Pipeline.run/3`.
  """
  @spec record_run(String.t(), map()) :: row()
  def record_run(agent_id, run_result) when is_map(run_result) do
    ts_ms = LemonCore.Clock.now_ms()
    generated = length(Map.get(run_result, :generated, []))
    skipped = Map.get(run_result, :skipped, [])
    blocked = Enum.count(skipped, fn {_key, reason} -> reason == :blocked_by_audit end)

    row = %{
      id: "synmet_#{ts_ms}_#{System.unique_integer([:positive])}",
      ts_ms: ts_ms,
      agent_id: to_string(agent_id),
      total_candidates: Map.get(run_result, :total_candidates, 0),
      generated: generated,
      blocked_by_audit: blocked,
      skipped_other: length(skipped) - blocked,
      latest_doc_ms: Map.get(run_result, :latest_doc_ms),
      gate: render_pass_gate(run_result)
    }

    Store.put(@table, row.id, row)
    prune()
    row
  end

  @doc """
  List recorded rows, newest first.

  ## Options

  - `:limit` — maximum rows to return (default: #{@default_limit})
  """
  @spec list(keyword()) :: [row()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    @table
    |> Store.list()
    |> Enum.map(fn {_id, value} -> normalize_row(value) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.ts_ms, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Sum every recorded row into the shape `LemonRouter.RolloutGate.evaluate_synthesis/1`
  expects.
  """
  @spec aggregate() :: aggregate()
  def aggregate do
    list(limit: @max_rows)
    |> Enum.reduce(%{total_candidates: 0, generated: 0, blocked_by_audit: 0}, fn row, acc ->
      %{
        total_candidates: acc.total_candidates + row.total_candidates,
        generated: acc.generated + row.generated + row.blocked_by_audit,
        blocked_by_audit: acc.blocked_by_audit + row.blocked_by_audit
      }
    end)
  end

  @doc """
  Evaluate the `:skill_synthesis_drafts` rollout gate over all recorded rows.

  Returns `:no_data` when nothing has been recorded yet.
  """
  @spec gate_status() ::
          {:ready, map()} | {:not_ready, [String.t()], map()} | :no_data
  def gate_status do
    case aggregate() do
      %{total_candidates: 0} -> :no_data
      agg -> RolloutGate.evaluate_synthesis(agg)
    end
  end

  @doc """
  Delete every recorded row. Intended for operator cleanup and tests.
  """
  @spec clear() :: :ok
  def clear do
    @table
    |> Store.list()
    |> Enum.each(fn {id, _value} -> Store.delete(@table, id) end)
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Per-pass informational verdict; the aggregate gate in gate_status/0 is what
  # actually governs graduation.
  defp render_pass_gate(run_result) do
    case RolloutGate.evaluate_synthesis_from_run(run_result) do
      {:pass, _notes} -> "pass"
      {:fail, _failures} -> "fail"
    end
  rescue
    _ -> "fail"
  end

  defp prune do
    rows =
      @table
      |> Store.list()
      |> Enum.map(fn {id, value} -> {id, normalize_row(value)} end)
      |> Enum.reject(fn {_id, row} -> is_nil(row) end)

    if length(rows) > @max_rows do
      rows
      |> Enum.sort_by(fn {_id, row} -> row.ts_ms end, :desc)
      |> Enum.drop(@max_rows)
      |> Enum.each(fn {id, _row} -> Store.delete(@table, id) end)
    end

    :ok
  end

  # Store backends may round-trip values through serialization, so rows come
  # back with either atom or string keys.
  defp normalize_row(value) when is_map(value) do
    %{
      id: to_string(field(value, :id) || ""),
      ts_ms: integer_field(value, :ts_ms, 0),
      agent_id: to_string(field(value, :agent_id) || ""),
      total_candidates: integer_field(value, :total_candidates, 0),
      generated: integer_field(value, :generated, 0),
      blocked_by_audit: integer_field(value, :blocked_by_audit, 0),
      skipped_other: integer_field(value, :skipped_other, 0),
      latest_doc_ms: optional_integer_field(value, :latest_doc_ms),
      gate: to_string(field(value, :gate) || "")
    }
  end

  defp normalize_row(_value), do: nil

  defp field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp integer_field(map, key, default) do
    case field(map, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp optional_integer_field(map, key) do
    case field(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end
end
