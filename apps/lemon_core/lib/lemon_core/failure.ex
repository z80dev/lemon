defmodule LemonCore.Failure do
  @moduledoc """
  Reports a failure that was caught, so that catching it does not hide it.

  `docs/platform/failure-handling.md` is the policy this module serves: a
  function may catch an exception at a boundary as long as the failure is
  observable, the caller receives an accurate outcome, and continuing
  leaves valid state. This module is the first of the three. A `rescue` or
  `catch` clause calls `log/4` (or `log_caught/5` for a caught throw or
  exit) with a short description of what was being attempted, and the log
  carries the exception, the stacktrace and the standard `crash_reason`
  metadata that log handlers and telemetry already understand:

      def handle_inbound(state, message) do
        route(state, message)
      rescue
        exception ->
          Failure.log("inbound message handling", exception, __STACKTRACE__)
          state
      end

  The default level is `:warning`, the level for a boundary that degrades
  and carries on. Pass `level: :error` where the failure means work was
  lost or a bug reached production, and `level: :debug` only for
  diagnostics whose absence changes nothing for a user.
  """

  require Logger

  @type level :: :debug | :info | :warning | :error

  @doc """
  Logs a rescued exception with its stacktrace.

  `what` names the attempt in a few words, in the caller's vocabulary
  ("media group flush", "run watchdog timeout"). The message reads
  `<what> raised: <formatted exception and stacktrace>`.

  Options: `level:` (default `:warning`) and any extra Logger metadata under
  `metadata:`.
  """
  @spec log(String.t(), Exception.t() | term(), Exception.stacktrace(), keyword()) :: :ok
  def log(what, exception, stacktrace, opts \\ []) when is_binary(what) and is_list(stacktrace) do
    emit(
      Keyword.get(opts, :level, :warning),
      what <> " raised: " <> Exception.format(:error, exception, stacktrace),
      [crash_reason: {exception, stacktrace}] ++ Keyword.get(opts, :metadata, [])
    )
  end

  @doc """
  Logs a caught throw or exit with its stacktrace.

  For a `catch kind, reason` clause; `kind` is `:throw`, `:exit` or `:error`
  and `reason` is the caught term. Same options as `log/4`.
  """
  @spec log_caught(String.t(), :throw | :exit | :error, term(), Exception.stacktrace(), keyword()) ::
          :ok
  def log_caught(what, kind, reason, stacktrace, opts \\ [])
      when is_binary(what) and kind in [:throw, :exit, :error] and is_list(stacktrace) do
    emit(
      Keyword.get(opts, :level, :warning),
      what <> " #{verb(kind)}: " <> Exception.format(kind, reason, stacktrace),
      [crash_reason: {crash_term(kind, reason), stacktrace}] ++ Keyword.get(opts, :metadata, [])
    )
  end

  defp verb(:throw), do: "threw"
  defp verb(:exit), do: "exited"
  defp verb(:error), do: "raised"

  # `crash_reason` carries an exception or an exit reason; a throw is
  # recorded the way the runtime reports an uncaught one.
  defp crash_term(:throw, reason), do: {:nocatch, reason}
  defp crash_term(_kind, reason), do: reason

  defp emit(:debug, message, metadata), do: Logger.debug(message, metadata)
  defp emit(:info, message, metadata), do: Logger.info(message, metadata)
  defp emit(:warning, message, metadata), do: Logger.warning(message, metadata)
  defp emit(:error, message, metadata), do: Logger.error(message, metadata)
end
