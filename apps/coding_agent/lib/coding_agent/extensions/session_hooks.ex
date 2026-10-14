defmodule CodingAgent.Extensions.SessionHooks do
  @moduledoc """
  Runs the observe-only extension session lifecycle hooks.

    * `:on_session_start` — `fn %{session_id, cwd, session_scope} -> any end`,
      fired once after a session (new or resumed) finishes starting.
    * `:on_session_shutdown` — `fn %{session_id, cwd, reason} -> any end`,
      fired when the session process terminates.

  Handlers run in registration order inside a separate, unlinked process.
  Return values are ignored and a failing handler does not affect the others.
  The whole event is bounded by a timeout (default 2 seconds); a handler still
  running at the deadline is killed so a slow extension cannot hold up session
  start or shutdown.
  """

  require Logger

  @default_timeout_ms 2_000

  @doc """
  Fires `:on_session_start` handlers from `hooks` with `event`.
  """
  @spec session_start(keyword([function()]), map(), keyword()) :: :ok
  def session_start(hooks, event, opts \\ []) do
    run(hooks, :on_session_start, Map.take(event, [:session_id, :cwd, :session_scope]), opts)
  end

  @doc """
  Fires `:on_session_shutdown` handlers from `hooks` with `event`.
  """
  @spec session_shutdown(keyword([function()]), map(), keyword()) :: :ok
  def session_shutdown(hooks, event, opts \\ []) do
    run(hooks, :on_session_shutdown, Map.take(event, [:session_id, :cwd, :reason]), opts)
  end

  defp run(hooks, event_name, event, opts) when is_list(hooks) do
    case Keyword.get(hooks, event_name, []) do
      [] -> :ok
      handlers -> run_bounded(handlers, event_name, event, opts)
    end
  end

  defp run(_hooks, _event_name, _event, _opts), do: :ok

  defp run_bounded(handlers, event_name, event, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    {pid, ref} =
      spawn_monitor(fn ->
        Enum.each(handlers, &invoke(&1, event_name, event))
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.warning("Extension #{event_name} hooks timed out after #{timeout}ms")
        :ok
    end
  end

  defp invoke(handler, event_name, event) do
    handler.(event)
  rescue
    exception ->
      Logger.warning("Extension #{event_name} hook failed: #{inspect(exception.__struct__)}")
  catch
    kind, _reason ->
      Logger.warning("Extension #{event_name} hook failed: #{kind}")
  end
end
