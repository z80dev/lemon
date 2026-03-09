defmodule LemonSim.Runner do
  @moduledoc """
  Lightweight decision runner.

  This runner can ingest a batch of events and stop early once a decision is
  required, which supports multiplayer/turn-based pacing.
  """

  alias LemonSim.{DecisionFrame, DecisionSignal, EventCoalescer}
  alias LemonSim.DecisionAdapters.ToolResultEvents

  @type decision_modules :: %{
          required(:action_space) => module(),
          required(:projector) => module(),
          required(:decider) => module()
        }

  @type step_modules :: %{
          required(:action_space) => module(),
          required(:projector) => module(),
          required(:decider) => module(),
          required(:updater) => module(),
          optional(:decision_adapter) => module()
        }

  @doc """
  Applies events in order and stops on the first `:decide` signal.
  """
  @spec ingest_events(LemonSim.State.t(), [LemonSim.Event.t() | map()], module(), keyword()) ::
          {:ok, LemonSim.State.t(), LemonSim.DecisionSignal.t()} | {:error, term()}
  def ingest_events(state, events, updater, opts \\ [])
      when is_list(events) and is_atom(updater) do
    with {:ok, coalesced_events} <- maybe_coalesce(events, opts) do
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

  @doc """
  Runs one composed turn: decide once, adapt decision to events, then ingest.
  """
  @spec step(LemonSim.State.t(), step_modules(), keyword()) ::
          {:ok,
           %{
             decision: map(),
             events: [LemonSim.Event.t() | map()],
             state: LemonSim.State.t(),
             signal: LemonSim.DecisionSignal.t()
           }}
          | {:error, term()}
  def step(
        state,
        %{
          action_space: action_space,
          projector: projector,
          decider: decider,
          updater: updater
        } = modules,
        opts \\ []
      )
      when is_atom(action_space) and is_atom(projector) and is_atom(decider) and is_atom(updater) do
    decision_adapter = Map.get(modules, :decision_adapter, ToolResultEvents)

    with {:ok, decision, _state} <- decide_once(state, modules, opts),
         {:ok, events} <- adapt_events(decision_adapter, decision, state, opts),
         {:ok, next_state, signal} <- ingest_events(state, events, updater, opts) do
      {:ok, %{decision: decision, events: events, state: next_state, signal: signal}}
    end
  end

  @doc """
  Repeatedly runs composed steps until a terminal state is reached.
  """
  @spec run_until_terminal(LemonSim.State.t(), step_modules(), keyword()) ::
          {:ok, LemonSim.State.t()} | {:error, term()}
  def run_until_terminal(state, modules, opts \\ [])
      when is_map(modules) and is_list(opts) do
    terminal? = Keyword.get(opts, :terminal?, fn _state -> false end)

    if is_function(terminal?, 1) do
      do_run_until_terminal(state, modules, opts, terminal?, 0)
    else
      {:error, {:invalid_terminal_predicate, terminal?}}
    end
  end

  defp do_run_until_terminal(state, modules, opts, terminal?, turn) do
    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 50))

    cond do
      terminal?.(state) ->
        {:ok, state}

      turn >= max_turns ->
        {:error, {:turn_limit_exceeded, max_turns}}

      true ->
        maybe_notify(Keyword.get(opts, :on_before_step), turn + 1, state)

        case step(state, modules, opts) do
          {:ok, result} ->
            maybe_notify(Keyword.get(opts, :on_after_step), turn + 1, result)
            do_run_until_terminal(result.state, modules, opts, terminal?, turn + 1)

          {:error, reason} ->
            {:error, {:step_failed, reason}}
        end
    end
  end

  defp maybe_coalesce(events, opts) do
    case Keyword.get(opts, :coalescer) do
      nil ->
        {:ok, events}

      coalescer when is_atom(coalescer) ->
        if function_exported?(coalescer, :coalesce, 2) do
          {:ok, coalescer.coalesce(events, opts)}
        else
          {:error, {:invalid_coalescer, coalescer}}
        end
    end
  end

  defp adapt_events(decision_adapter, decision, state, opts) do
    case direct_events(decision) do
      {:ok, events} ->
        {:ok, events}

      :no_events ->
        if Code.ensure_loaded?(decision_adapter) and
             function_exported?(decision_adapter, :to_events, 3) do
          case decision_adapter.to_events(decision, state, opts) do
            {:ok, events} when is_list(events) ->
              {:ok, events}

            {:ok, events} ->
              {:error, {:invalid_events, events}}

            {:error, _reason} = error ->
              error

            other ->
              {:error, {:invalid_decision_adapter_result, other}}
          end
        else
          {:error, {:invalid_decision_adapter, decision_adapter}}
        end
    end
  end

  defp direct_events(%{} = decision) do
    cond do
      is_list(fetch(decision, :events, "events", nil)) ->
        {:ok, fetch(decision, :events, "events", [])}

      not is_nil(fetch(decision, :event, "event", nil)) ->
        {:ok, [fetch(decision, :event, "event", nil)]}

      true ->
        :no_events
    end
  end

  defp direct_events(_decision), do: :no_events

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp maybe_notify(callback, turn, payload) when is_function(callback, 2) do
    callback.(turn, payload)
    :ok
  end

  defp maybe_notify(_callback, _turn, _payload), do: :ok
end
