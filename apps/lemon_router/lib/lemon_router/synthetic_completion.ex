defmodule LemonRouter.SyntheticCompletion do
  @moduledoc """
  The router's one way to end a run whose engine will never report a result.

  The engine runtime owns the real `:run_completed`. When the router knows
  that event is not coming (the runtime never accepted the run, the run was
  aborted before it bound to an engine process, the engine process died
  without reporting, or the watchdog gave up), the router ends the logical
  run itself with the same event shape, marked `synthetic: true` in the
  event meta and, where the stage is known, with a `failure_stage`.

  Subscribers therefore see exactly one terminal event per run, built by
  `LemonCore.Events.RunCompleted.failure/2`, whichever layer produced it.
  """

  alias LemonCore.{Bus, Event}
  alias LemonCore.Events.RunCompleted

  @type option ::
          {:duration_ms, non_neg_integer() | nil}
          | {:failure_stage, atom()}
          | {:engine, String.t()}

  @doc """
  Broadcasts a synthetic `:run_completed` for `run_id` on its run topic.

  `error` is the completion's error term. Options: `:duration_ms`,
  `:failure_stage` (added to the event meta), `:engine`.
  """
  @spec broadcast(String.t(), String.t() | nil, term(), [option()]) :: :ok
  def broadcast(run_id, session_key, error, opts \\ []) when is_binary(run_id) do
    payload =
      RunCompleted.failure(error,
        duration_ms: Keyword.get(opts, :duration_ms),
        engine: Keyword.get(opts, :engine)
      )

    meta =
      %{run_id: run_id, session_key: session_key, synthetic: true}
      |> put_failure_stage(Keyword.get(opts, :failure_stage))

    Bus.broadcast(Bus.run_topic(run_id), Event.new(:run_completed, payload, meta))
  end

  defp put_failure_stage(meta, nil), do: meta

  defp put_failure_stage(meta, stage) when is_atom(stage),
    do: Map.put(meta, :failure_stage, stage)
end
