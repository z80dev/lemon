defmodule LemonAutomation.TestCronManager do
  @moduledoc """
  Runs `LemonAutomation.CronManager` under the ExUnit test supervisor.

  Tests that stop or kill the scheduler must call `isolate!/0` first. Their
  restarts then consume the test supervisor's restart budget instead of
  `LemonAutomation.Supervisor`'s default intensity (3 restarts in 5 seconds),
  which would otherwise shut down `:lemon_automation` for the rest of the suite.

  ExUnit stops test-supervised children before running `on_exit/1` callbacks,
  and runs those callbacks in reverse registration order. Call `isolate!/0`
  after registering any cleanup that uses the `CronManager` API so the global
  child is restored before that cleanup runs.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias LemonAutomation.CronManager

  @doc "Replace the application-supervised CronManager for the current test."
  @spec isolate!() :: pid()
  def isolate! do
    :ok = Supervisor.terminate_child(LemonAutomation.Supervisor, CronManager)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(LemonAutomation.Supervisor, CronManager)
    end)

    start_supervised!(CronManager)
  end
end
