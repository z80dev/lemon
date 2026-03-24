defmodule Ai.Providers.StreamingHelper do
  @moduledoc """
  Shared helper for the identical stream/3 setup pattern across all AI providers.

  Each provider's stream/3 follows the same structure:
  1. Start an EventStream with owner monitoring and timeout
  2. Spawn a supervised task that calls the provider's do_stream logic
  3. Attach the task to the stream for lifecycle management
  """

  alias Ai.EventStream

  @default_stream_timeout 300_000
  @default_max_queue 10_000

  @doc """
  Sets up the standard streaming infrastructure and spawns the provider's
  streaming function under supervision.

  `do_stream_fn` must be a function with arity 4: `(stream, model, context, opts)`.
  """
  def start_streaming(model, context, opts, do_stream_fn) do
    owner = self()
    stream_timeout = opts.stream_timeout || @default_stream_timeout

    {:ok, stream} =
      EventStream.start_link(
        owner: owner,
        max_queue: @default_max_queue,
        timeout: stream_timeout
      )

    {:ok, task_pid} =
      Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
        do_stream_fn.(stream, model, context, opts)
      end)

    EventStream.attach_task(stream, task_pid)

    {:ok, stream}
  end
end
