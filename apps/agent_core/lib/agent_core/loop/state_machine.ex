defmodule AgentCore.Loop.StateMachine do
  @moduledoc false

  @states [
    :initializing,
    :await_model,
    :normalizing_response,
    :executing_tools,
    :awaiting_tool_results,
    :recovering_provider_error,
    :compressing_context,
    :finalizing,
    :aborted
  ]

  @transitions %{
    nil => [:initializing],
    initializing: [:await_model],
    await_model: [:normalizing_response, :aborted, :recovering_provider_error],
    normalizing_response: [
      :await_model,
      :executing_tools,
      :recovering_provider_error,
      :finalizing,
      :aborted
    ],
    executing_tools: [:awaiting_tool_results, :aborted],
    awaiting_tool_results: [:await_model, :finalizing, :aborted],
    recovering_provider_error: [:finalizing],
    compressing_context: [:await_model, :recovering_provider_error],
    finalizing: [],
    aborted: []
  }

  @type state ::
          :initializing
          | :await_model
          | :normalizing_response
          | :executing_tools
          | :awaiting_tool_results
          | :recovering_provider_error
          | :compressing_context
          | :finalizing
          | :aborted

  @spec states() :: [state()]
  def states, do: @states

  @spec transition(state() | nil, state()) :: {:ok, state()} | {:error, term()}
  def transition(from, to) when to in @states do
    if to in Map.fetch!(@transitions, from) do
      {:ok, to}
    else
      {:error, {:invalid_loop_state_transition, from, to}}
    end
  end

  def transition(from, to), do: {:error, {:unknown_loop_state, from, to}}

  @spec transition!(state() | nil, state()) :: state()
  def transition!(from, to) do
    case transition(from, to) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end
end
