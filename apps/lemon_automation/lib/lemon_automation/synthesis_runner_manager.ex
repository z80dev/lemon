defmodule LemonAutomation.SynthesisRunnerManager do
  @moduledoc """
  Interval scheduler for `LemonAutomation.SynthesisRunner`.

  Ticks once a minute, defers while the router reports active sessions, and
  spawns at most one synthesis pass at a time. Interval gating itself lives in
  the runner's durable state (`:synthesis_runner_state`), so a restart does not
  reset the clock and re-run early.
  """

  alias LemonAutomation.{IntervalRunner, SynthesisRunner}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    IntervalRunner.start_link(__MODULE__, SynthesisRunner, opts)
  end

  @doc """
  Force one scheduler tick.
  """
  @spec tick() :: :ok
  def tick, do: GenServer.cast(__MODULE__, :tick)
end
