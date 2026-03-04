defmodule LemonSim.Runner do
  @moduledoc """
  Lightweight decision runner.

  This runner can ingest a batch of events and stop early once a decision is
  required, which supports multiplayer/turn-based pacing.
  """

  alias LemonSim.{DecisionFrame, DecisionSignal, EventCoalescer}

  @type decision_modules :: %{
          required(:action_space) => module(),
          required(:projector) => module(),
          required(:decider) => module()
        }

  @doc """
  Applies events in order and stops on the first `:decide` signal.
  """
  @spec ingest_events(LemonSim.State.t(), [LemonSim.Event.t() | map()], module(), keyword()) ::
          {:ok, LemonSim.State.t(), LemonSim.DecisionSignal.t()} | {:error, term()}
  def ingest_events(state, events, updater, opts \\ [])
      when is_list(events) and is_atom(updater) do
    coalesced_events = maybe_coalesce(events, opts)

    Enum.reduce_while(coalesced_events, {:ok, state, :skip}, fn event,
                                                                {:ok, acc_state, _signal} ->
      case updater.apply_event(acc_state, event, opts) do
        {:ok, next_state, signal} ->
          if DecisionSignal.decide?(signal) do
            {:halt, {:ok, next_state, signal}}
          else
            {:cont, {:ok, next_state, signal}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc """
  Runs one decision against dynamically generated legal tools.
  """
  @spec decide_once(LemonSim.State.t(), decision_modules(), keyword()) ::
          {:ok, map(), LemonSim.State.t()} | {:error, term()}
  def decide_once(
        state,
        %{action_space: action_space, projector: projector, decider: decider},
        opts
      )
      when is_atom(action_space) and is_atom(projector) and is_atom(decider) do
    with {:ok, tools} <- action_space.tools(state, opts),
         frame <- DecisionFrame.from_state(state, opts),
         {:ok, context} <- projector.project(frame, tools, opts),
         {:ok, decision} <- decider.decide(context, tools, opts) do
      {:ok, decision, state}
    end
  end

  defp maybe_coalesce(events, opts) do
    case Keyword.get(opts, :coalescer) do
      nil ->
        events

      coalescer when is_atom(coalescer) ->
        if function_exported?(coalescer, :coalesce, 2) do
          coalescer.coalesce(events, opts)
        else
          raise ArgumentError,
                "coalescer #{inspect(coalescer)} must implement #{inspect(EventCoalescer)}"
        end
    end
  end
end
