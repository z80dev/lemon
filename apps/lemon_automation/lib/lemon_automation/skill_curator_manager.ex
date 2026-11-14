defmodule LemonAutomation.SkillCuratorManager do
  @moduledoc """
  Idle-triggered scheduler for the learned-skill curator.
  """

  alias LemonAutomation.{IntervalRunner, SkillCurator}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    IntervalRunner.start_link(__MODULE__, SkillCurator, opts, track_idle: true)
  end

  @doc """
  Force one scheduler tick.
  """
  @spec tick() :: :ok
  def tick, do: GenServer.cast(__MODULE__, :tick)
end
