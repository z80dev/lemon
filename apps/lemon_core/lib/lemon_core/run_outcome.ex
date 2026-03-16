defmodule LemonCore.RunOutcome do
  @moduledoc """
  Outcome labels for finalized runs.

  Provides heuristics for inferring `:success | :partial | :failure | :aborted | :unknown`
  from a run summary, plus support for explicit overrides.

  ## Outcome semantics

  | Outcome    | Meaning |
  |------------|---------|
  | `:success` | Run completed with `ok: true` and a non-empty answer. |
  | `:partial` | Run completed with `ok: true` but produced no substantive answer (e.g. tool-only run). |
  | `:failure` | Run completed with `ok: false` for a non-abort reason. |
  | `:aborted` | Run was cancelled by the user or watchdog. |
  | `:unknown` | Outcome cannot be determined from available data. |

  ## Heuristics

  `infer/1` checks the summary in order:

  1. Explicit `:outcome` field on the summary (operator/explicit override).
  2. `completed.ok` boolean with answer content → `:success` or `:partial`.
  3. `completed.ok == false` with error text → `:aborted` or `:failure`.
  4. Top-level `:ok` fallback for summaries without a `:completed` sub-map.
  5. Default: `:unknown`.

  ## Explicit overrides

  The caller may embed an explicit `:outcome` field in the summary map to bypass
  heuristics entirely.  This is the primary escape hatch for engines or external
  integrations that know the true outcome.

      summary = %{..., outcome: :aborted}
      RunOutcome.infer(summary)  # => :aborted
  """

  @type t :: :success | :partial | :failure | :aborted | :unknown

  @valid_outcomes [:success, :partial, :failure, :aborted, :unknown]

  @aborted_error_markers [
    "abort",
    "user_requested",
    "cancelled",
    "watchdog",
    "idle_timeout",
    "keepalive_cancelled"
  ]

  @doc """
  Returns the list of valid outcome atoms.
  """
  @spec valid_outcomes() :: [t()]
  def valid_outcomes, do: @valid_outcomes

  @doc """
  Returns `true` if `outcome` is a valid outcome atom.
  """
  @spec valid?(atom()) :: boolean()
  def valid?(outcome), do: outcome in @valid_outcomes

  @doc """
  Infer the run outcome from a finalized run summary map.

  Checks for an explicit `:outcome` override first, then applies heuristics
  based on the `completed.ok` boolean and answer/error content.

  Safe against malformed or partial summaries — always returns a valid outcome.
  """
  @spec infer(map()) :: t()
  def infer(summary) when is_map(summary) do
    # 1. Explicit override wins
    case explicit_outcome(summary) do
      {:ok, outcome} ->
        outcome

      :none ->
        # 2. Try completed sub-map
        completed = fetch(summary, :completed)

        if is_map(completed) do
          infer_from_completed(completed)
        else
          # 3. Try top-level ok/error/answer (flat summary format)
          infer_from_flat(summary)
        end
    end
  end

  def infer(_), do: :unknown

  @doc """
  Cast a raw value (atom or string) to an outcome atom.

  Returns `{:ok, outcome}` if valid, `:error` otherwise.
  """
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(outcome) when outcome in @valid_outcomes, do: {:ok, outcome}

  def cast(str) when is_binary(str) do
    atom =
      try do
        String.to_existing_atom(str)
      rescue
        _ -> nil
      end

    if atom in @valid_outcomes, do: {:ok, atom}, else: :error
  end

  def cast(_), do: :error

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp explicit_outcome(summary) do
    case fetch(summary, :outcome) do
      value when value in @valid_outcomes -> {:ok, value}
      _ -> :none
    end
  end

  defp infer_from_completed(completed) do
    ok = fetch(completed, :ok)

    cond do
      ok == true ->
        answer = fetch(completed, :answer)

        if non_empty_string?(answer) do
          :success
        else
          :partial
        end

      ok == false ->
        error = fetch(completed, :error)

        if aborted_error?(error) do
          :aborted
        else
          :failure
        end

      true ->
        :unknown
    end
  end

  defp infer_from_flat(summary) do
    ok = fetch(summary, :ok)

    cond do
      ok == true ->
        answer = fetch(summary, :answer)

        if non_empty_string?(answer) do
          :success
        else
          :partial
        end

      ok == false ->
        error = fetch(summary, :error)

        if aborted_error?(error) do
          :aborted
        else
          :failure
        end

      true ->
        :unknown
    end
  end

  defp aborted_error?(error) when is_binary(error) do
    lower = String.downcase(error)
    Enum.any?(@aborted_error_markers, &String.contains?(lower, &1))
  end

  defp aborted_error?(error) when is_atom(error) and not is_nil(error) do
    aborted_error?(Atom.to_string(error))
  end

  defp aborted_error?(_), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_), do: false

  # Fetch a key by atom, falling back to the string form.
  defp fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil
end
