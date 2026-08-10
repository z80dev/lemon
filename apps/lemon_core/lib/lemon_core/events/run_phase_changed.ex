defmodule LemonCore.Events.RunPhaseChanged do
  @moduledoc """
  A run moved between lifecycle phases. Published on `run:<run_id>` by both the gateway
  run process and the router's phase publisher.

  Replaces `LemonCore.RunPhaseEvent.build/1`, which was this struct written as a map.
  """

  use LemonCore.Events.Payload,
    type: :run_phase_changed,
    enforce: [:run_id, :phase, :source],
    fields: [
      run_id: nil,
      session_key: nil,
      conversation_key: nil,
      phase: nil,
      previous_phase: nil,
      source: nil,
      at: nil
    ]

  alias LemonCore.RunPhase

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_key: String.t() | nil,
          conversation_key: String.t() | nil,
          phase: atom(),
          previous_phase: atom() | nil,
          source: atom(),
          at: DateTime.t() | nil
        }

  @doc """
  Build a phase change, validating both phases against `LemonCore.RunPhase`.
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    phase = Keyword.fetch!(opts, :phase)
    previous_phase = Keyword.get(opts, :previous_phase)

    validate_phase!(phase, :phase)
    validate_phase!(previous_phase, :previous_phase)

    %__MODULE__{
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
