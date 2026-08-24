defmodule LemonAgent.AbortSignal do
  @moduledoc """
  Cooperative, ETS-backed abort signalling for the agent loop and tools.

  A signal is a plain `t:reference/0`. The loop checks it before each LLM call
  and tool batch; long-running tools should check it too and stop early when it
  is set, so cancellation is graceful rather than forced:

      def execute(args, %{abort_signal: signal} = _ctx) do
        if LemonAgent.AbortSignal.aborted?(signal), do: throw(:aborted)
        # ...
      end

  Reads and writes go through a `:public` ETS table with read/write
  concurrency, so `aborted?/1` is cheap to call in a hot loop. A long-lived
  owner process holds the table as its heir, so it survives a producer crash.

  ## Redirect state

  A signal also carries an independent *redirect* bit, stored alongside (not
  inside) the abort bit under the key `{ref, :redirect}`. A redirect asks the
  loop to cancel only the in-flight model request — keeping completed tool
  results — then retry with a queued correction appended. It never means
  "stop everything", so `aborted?/1` ignores it and tools keep running.
  Use `request_redirect/1`, `redirect_requested?/1`, and `clear_redirect/1`;
  `clear/1` clears both bits.
  """

  @table :agent_core_abort_signals

  @spec new() :: reference()
  def new do
    ensure_table()
    ref = make_ref()
    :ets.insert(@table, {ref, false})
    ref
  end

  @spec abort(reference()) :: :ok
  def abort(ref) when is_reference(ref) do
    ensure_table()
    :ets.insert(@table, {ref, true})
    :ok
  end

  @spec aborted?(reference() | nil) :: boolean()
  def aborted?(nil), do: false

  def aborted?(ref) when is_reference(ref) do
    ensure_table()

    case :ets.lookup(@table, ref) do
      [{^ref, true}] -> true
      _ -> false
    end
  end

  @spec request_redirect(reference() | nil) :: :ok
  def request_redirect(nil), do: :ok

  def request_redirect(ref) when is_reference(ref) do
    ensure_table()
    :ets.insert(@table, {{ref, :redirect}, true})
    :ok
  end

  @spec redirect_requested?(reference() | nil) :: boolean()
  def redirect_requested?(nil), do: false

  def redirect_requested?(ref) when is_reference(ref) do
    ensure_table()

    case :ets.lookup(@table, {ref, :redirect}) do
      [{{^ref, :redirect}, true}] -> true
      _ -> false
    end
  end

  @spec clear_redirect(reference() | nil) :: :ok
  def clear_redirect(nil), do: :ok

  def clear_redirect(ref) when is_reference(ref) do
    ensure_table()
    :ets.delete(@table, {ref, :redirect})
    :ok
  end

  @spec clear(reference() | nil) :: :ok
  def clear(nil), do: :ok

  def clear(ref) when is_reference(ref) do
    ensure_table()
    :ets.delete(@table, ref)
    :ets.delete(@table, {ref, :redirect})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        heir = Process.whereis(LemonAgent.AbortSignal.TableOwner)

        opts =
          [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ] ++
            if is_pid(heir) do
              [{:heir, heir, :ok}]
            else
              []
            end

        :ets.new(@table, opts)
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
