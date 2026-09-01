defmodule LemonCore.Events.RunCompleted do
  @moduledoc """
  A run reached a terminal state, successfully or not. Published on `run:<run_id>`.

  The most widely consumed payload in the umbrella — twelve subscribers across six apps.
  `meta.synthetic` marks completions the router fabricated because the engine never
  reported one (watchdog timeout, abort, gateway process death).
  """

  use LemonCore.Events.Payload,
    type: :run_completed,
    enforce: [:completed],
    fields: [completed: nil, duration_ms: nil]

  alias LemonCore.Events.Completion

  @type t :: %__MODULE__{
          completed: Completion.t(),
          duration_ms: non_neg_integer() | nil
        }

  @doc """
  The terminal event for a run that ended without a result from its engine.

  `error` says why; the completion carries `ok: false` and an empty answer.
  Options: `:duration_ms`, and the `:engine`, `:run_id`, `:session_key` and
  `:meta` recorded on the completion. Every synthetic completion in the
  platform is built here, so subscribers see one shape whether the run was
  never submitted, never started, timed out, was aborted, or lost its engine
  process; the publisher marks the event's meta with `synthetic: true` and a
  `failure_stage` where it knows one.
  """
  @spec failure(term(), keyword()) :: t()
  def failure(error, opts \\ []) when is_list(opts) do
    %__MODULE__{
      completed:
        Completion.new(%{
          ok: false,
          error: error,
          answer: "",
          engine: Keyword.get(opts, :engine),
          run_id: Keyword.get(opts, :run_id),
          session_key: Keyword.get(opts, :session_key),
          meta: Keyword.get(opts, :meta, %{})
        }),
      duration_ms: Keyword.get(opts, :duration_ms)
    }
  end

  @doc """
  Build from a legacy map, coercing the nested completion too.
  """
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    completed =
      case Map.get(attrs, :completed) || Map.get(attrs, "completed") do
        nil -> Completion.from_map(attrs)
        %Completion{} = completion -> completion
        completion when is_map(completion) -> Completion.from_map(completion)
        other -> other
      end

    %__MODULE__{
      completed: completed,
      duration_ms: Map.get(attrs, :duration_ms) || Map.get(attrs, "duration_ms")
    }
  end
end
