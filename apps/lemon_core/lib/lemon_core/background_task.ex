defmodule LemonCore.BackgroundTask do
  @moduledoc """
  Centralized background task spawning with explicit supervisor and fallback policy.

  This module replaces the duplicated `start_background_task/1` helpers that were
  scattered across `CodingAgent.Coordinator`, `CodingAgent.Session.CompactionManager`,
  `LemonAutomation.CronManager`, `LemonAutomation.HeartbeatManager`, and
  `LemonChannels.Adapters.Telegram.Transport`.

  ## Supervised (default)

  By default, tasks are started under the given Task.Supervisor. If no `:supervisor`
  option is provided, `LemonCore.BackgroundTaskSupervisor` is used.

  If the supervisor is not running, the call returns `{:error, :supervisor_not_available}`
  instead of silently falling back to an unsupervised task.

  ## Unsupervised fallback (opt-in)

  Pass `allow_unsupervised: true` to explicitly allow fallback to `Task.start/1` when
  the supervisor is unavailable. This makes the degradation visible at the call site
  rather than hidden inside a helper.

      LemonCore.BackgroundTask.start(fn -> do_work() end, allow_unsupervised: true)

  ## Options

    * `:supervisor` - A `Task.Supervisor` name or pid (default: `LemonCore.BackgroundTaskSupervisor`)
    * `:allow_unsupervised` - When `true`, falls back to `Task.start/1` if the
      supervisor is not available (default: `false`)
  """

  require Logger

  @default_supervisor LemonCore.BackgroundTaskSupervisor

  @spec start((-> any()), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(fun, opts \\ []) when is_function(fun, 0) do
    supervisor = Keyword.get(opts, :supervisor, @default_supervisor)
    allow_unsupervised = Keyword.get(opts, :allow_unsupervised, false)

    result = try_start_supervised(supervisor, fun)

    case result do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :supervisor_not_available} ->
        handle_supervisor_unavailable(fun, supervisor, allow_unsupervised)

      {:error, reason} ->
        Logger.warning(
          "[BackgroundTask] Supervisor #{inspect(supervisor)} rejected task: #{inspect(reason)}"
        )

        if allow_unsupervised do
          Logger.warning("[BackgroundTask] Falling back to unsupervised Task.start/1")
          Task.start(fun)
        else
          {:error, reason}
        end
    end
  end

  # Attempt to start a child under the supervisor, normalizing noproc errors
  # (whether returned or raised as exits) into {:error, :supervisor_not_available}.
  defp try_start_supervised(supervisor, fun) do
    case Task.Supervisor.start_child(supervisor, fun) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:noproc, _}} -> {:error, :supervisor_not_available}
      {:error, :noproc} -> {:error, :supervisor_not_available}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:noproc, _} -> {:error, :supervisor_not_available}
  end

  defp handle_supervisor_unavailable(fun, supervisor, true) do
    Logger.warning(
      "[BackgroundTask] Supervisor #{inspect(supervisor)} not available; " <>
        "falling back to unsupervised Task.start/1 (allow_unsupervised: true)"
    )

    Task.start(fun)
  end

  defp handle_supervisor_unavailable(_fun, supervisor, false) do
    {:error, {:supervisor_not_available, supervisor}}
  end
end
