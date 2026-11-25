defmodule LemonAgent.EventStream do
  @moduledoc """
  Published agent-stream facade over `LemonAi.EventStream`.

  This module retains the LemonAgent package API; it owns no process or queue.
  Agent completion emits `{:agent_end, messages}` and errors retain their reason
  and partial state. Cancellation drains accepted events before its terminal.
  See `LemonAi.EventStream` for queue, ownership and timeout options.
  """

  @type t :: LemonAi.EventStream.t()
  @type event :: term()
  @type drop_strategy :: LemonAi.EventStream.drop_strategy()
  @type option :: LemonAi.EventStream.option() | {:abort_signal, LemonAgent.AbortSignal.t() | nil}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []), do: LemonAi.EventStream.start_link(agent_options(opts))
  def start(opts \\ []), do: LemonAi.EventStream.start(agent_options(opts))
  defdelegate attach_task(stream, task_pid), to: LemonAi.EventStream
  defdelegate push(stream, event), to: LemonAi.EventStream
  defdelegate push!(stream, event), to: LemonAi.EventStream
  defdelegate push_async(stream, event), to: LemonAi.EventStream
  defdelegate complete(stream, messages), to: LemonAi.EventStream

  def error(stream, reason, partial_state \\ nil),
    do: LemonAi.EventStream.error(stream, reason, partial_state)

  def cancel(stream, reason \\ :canceled), do: LemonAi.EventStream.cancel(stream, reason)
  defdelegate events(stream), to: LemonAi.EventStream
  def result(stream, timeout \\ :infinity), do: LemonAi.EventStream.result(stream, timeout)
  defdelegate stats(stream), to: LemonAi.EventStream

  defp agent_options(opts) do
    {signal, opts} = Keyword.pop(opts, :abort_signal)
    grace = Application.get_env(:lemon_agent, :event_stream_cancel_grace_ms, 100)
    grace = if is_integer(grace) and grace > 0, do: grace, else: 100

    opts
    |> Keyword.put(:event_format, :agent)
    |> Keyword.put(:task_shutdown_grace_ms, grace)
    |> Keyword.put(:on_cancel, if(signal, do: fn -> LemonAgent.AbortSignal.abort(signal) end))
  end
end
