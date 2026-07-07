defmodule LemonSim.Kernel.Runner do
  @moduledoc """
  Lightweight decision runner.

  This runner can ingest a batch of events and stop early once a decision is
  required, which supports multiplayer/turn-based pacing.
  """

  alias LemonSim.Kernel.{DecisionFrame, DecisionSignal, State}
  alias LemonSim.Kernel.DecisionAdapters.ToolResultEvents

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

  Pass `halt_on_decide?: false` to apply every event regardless of signals;
  the returned signal is then the first `:decide` encountered (or the last
  signal when none required a decision). `step/3` uses this mode because its
  events come from already-executed tool calls — dropping any of them would
  desynchronize the world from what the model was told succeeded.
  """
  @spec ingest_events(
          LemonSim.Kernel.State.t(),
          [LemonSim.Kernel.Event.t() | map()],
          module(),
          keyword()
        ) ::
          {:ok, LemonSim.Kernel.State.t(), LemonSim.Kernel.DecisionSignal.t()} | {:error, term()}
  def ingest_events(state, events, updater, opts \\ [])
      when is_list(events) and is_atom(updater) do
    halt_on_decide? = Keyword.get(opts, :halt_on_decide?, true)

    with {:ok, coalesced_events} <- maybe_coalesce(events, opts) do
      Enum.reduce_while(coalesced_events, {:ok, state, :skip}, fn event,
                                                                  {:ok, acc_state, acc_signal} ->
        case updater.apply_event(acc_state, event, opts) do
          {:ok, next_state, signal} ->
            cond do
              not DecisionSignal.decide?(signal) ->
                {:cont, {:ok, next_state, keep_first_decide(acc_signal, signal)}}

              halt_on_decide? ->
                {:halt, {:ok, next_state, signal}}

              true ->
                {:cont, {:ok, next_state, keep_first_decide(acc_signal, signal)}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp keep_first_decide(acc_signal, signal) do
    if DecisionSignal.decide?(acc_signal), do: acc_signal, else: signal
  end

  @doc """
  Runs one decision against dynamically generated legal tools.
  """
  @spec decide_once(LemonSim.Kernel.State.t(), decision_modules(), keyword()) ::
          {:ok, map(), LemonSim.Kernel.State.t()} | {:error, term()}
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

  All adapted events are applied even when one signals `:decide` mid-batch
  (the tools behind them already executed); pass `halt_on_decide?: true` to
  restore early-stop ingestion.
  """
  @spec step(LemonSim.Kernel.State.t(), step_modules(), keyword()) ::
          {:ok,
           %{
             decision: map(),
             events: [LemonSim.Kernel.Event.t() | map()],
             state: LemonSim.Kernel.State.t(),
             signal: LemonSim.Kernel.DecisionSignal.t()
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
         {:ok, next_state, signal} <-
           ingest_events(state, events, updater, Keyword.put_new(opts, :halt_on_decide?, false)) do
      {:ok, %{decision: decision, events: events, state: next_state, signal: signal}}
    end
  end

  @doc """
  Repeatedly runs composed steps until a terminal state is reached.

  ## Options

    * `:terminal?` - `fn state -> boolean` (default: never terminal)
    * `:driver_max_turns` / `:max_turns` - turn budget (default: 50)
    * `:on_before_step` - `fn turn, state -> any` notification, called before
      each step; its return value is ignored
    * `:on_after_step` - `fn turn, result -> any`, called after each
      successful step. Returning `{:ok, %LemonSim.Kernel.State{}} = new_state}`
      replaces the state fed into the next iteration (and the state returned
      on eventual `{:ok, final_state}` / carried in a resumable error) — this
      is how a caller folds its own bookkeeping (e.g. a decision-trace log)
      into the state the decider itself sees on later turns. Any other return
      value (including the historical `:ok`) is notify-only, exactly as
      before: the next iteration uses the raw `result.state`.
    * `:resumable?` - when `true`, failures are returned as
      `{:error, reason, state}` instead of `{:error, reason}`, where `state`
      is the last state a step successfully completed on (after any
      `:on_after_step` transform) — i.e. the point a caller can resume
      `run_until_terminal/3` from. Defaults to `false`, preserving the
      original 2-tuple error shape for existing callers.
  """
  @spec run_until_terminal(State.t(), step_modules(), keyword()) ::
          {:ok, State.t()} | {:error, term()} | {:error, term(), State.t()}
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
        step_error(opts, {:turn_limit_exceeded, max_turns}, state)

      true ->
        maybe_notify(Keyword.get(opts, :on_before_step), turn + 1, state)

        case step(state, modules, opts) do
          {:ok, result} ->
            next_state = apply_after_step(Keyword.get(opts, :on_after_step), turn + 1, result)
            do_run_until_terminal(next_state, modules, opts, terminal?, turn + 1)

          {:error, reason} ->
            step_error(opts, {:step_failed, reason}, state)
        end
    end
  end

  defp step_error(opts, reason, state) do
    if Keyword.get(opts, :resumable?, false) do
      {:error, reason, state}
    else
      {:error, reason}
    end
  end

  defp apply_after_step(callback, turn, result) when is_function(callback, 2) do
    case callback.(turn, result) do
      {:ok, %State{} = new_state} -> new_state
      _ -> result.state
    end
  end

  defp apply_after_step(_callback, _turn, result), do: result.state

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

      coalescer ->
        {:error, {:invalid_coalescer, coalescer}}
    end
  end

  defp adapt_events(decision_adapter, decision, state, opts) do
    if executed_calls?(decision) and decision_adapter != ToolResultEvents do
      adapter_events(decision_adapter, decision, state, opts)
    else
      direct_or_adapter_events(decision_adapter, decision, state, opts)
    end
  end

  defp direct_or_adapter_events(decision_adapter, decision, state, opts) do
    case direct_events(decision) do
      {:ok, events} ->
        {:ok, events}

      :no_events ->
        adapter_events(decision_adapter, decision, state, opts)
    end
  end

  defp adapter_events(decision_adapter, decision, state, opts) do
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

  defp executed_calls?(%{} = decision),
    do: is_list(fetch(decision, :executed_calls, "executed_calls", nil))

  defp executed_calls?(_decision), do: false

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp maybe_notify(callback, turn, payload) when is_function(callback, 2) do
    callback.(turn, payload)
    :ok
  end

  defp maybe_notify(_callback, _turn, _payload), do: :ok
end
