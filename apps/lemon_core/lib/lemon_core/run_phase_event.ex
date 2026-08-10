defmodule LemonCore.RunPhaseEvent do
  @moduledoc """
  Helper for canonical run phase change payloads emitted by router and gateway.

  Superseded by `LemonCore.Events.RunPhaseChanged`, which is the same shape as a struct.
  This module now builds that struct and returns it as a map for callers that still expect
  one; new code should use `LemonCore.Events.RunPhaseChanged.build/1` directly.
  """

  alias LemonCore.Events.RunPhaseChanged

  @deprecated "Use LemonCore.Events.RunPhaseChanged.build/1"
  @spec build(keyword()) :: map()
  def build(opts) do
    opts
    |> RunPhaseChanged.build()
    |> Map.from_struct()
    |> Map.put(:type, :run_phase_changed)
  end
end
