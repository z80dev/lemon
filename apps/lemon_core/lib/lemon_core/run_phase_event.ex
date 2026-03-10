defmodule LemonCore.RunPhaseEvent do
  @moduledoc """
  Helper for canonical run phase change payloads emitted by router and gateway.
  """

  alias LemonCore.RunPhase

  @spec build(keyword()) :: map()
  def build(opts) do
    phase = Keyword.fetch!(opts, :phase)
    previous_phase = Keyword.get(opts, :previous_phase)

    validate_phase!(phase, :phase)
    validate_phase!(previous_phase, :previous_phase)

    %{
      type: :run_phase_changed,
      run_id: Keyword.fetch!(opts, :run_id),
      session_key: Keyword.get(opts, :session_key),
      conversation_key: Keyword.get(opts, :conversation_key),
      phase: phase,
      previous_phase: previous_phase,
      source: Keyword.fetch!(opts, :source),
      at: Keyword.get(opts, :at, DateTime.utc_now())
    }
  end

  defp validate_phase!(nil, :previous_phase), do: :ok

  defp validate_phase!(phase, field) do
    if RunPhase.valid?(phase) do
      :ok
    else
      raise ArgumentError, "invalid #{field}: #{inspect(phase)}"
    end
  end
end
