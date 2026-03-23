defmodule LemonChannels.Adapters.Telegram.Transport.ActionRunner do
  @moduledoc """
  Executes Telegram transport-local side effects produced by the ingress
  pipeline.

  The action vocabulary stays intentionally small and adapter-specific so PR5
  can simplify Telegram ingress without introducing a shared framework.
  """

  @type callbacks :: %{
          optional(:execute_inbound_message) => (map(), map() -> map()),
          optional(:handle_inbound_message) => (map(), map() -> map()),
          optional(:handle_callback_query) => (map(), map() -> any()),
          optional(:index_known_target) => (map(), map() -> map()),
          optional(:submit_buffer) => (map(), map() -> map()),
          optional(:process_media_group) => (map(), map() -> any()),
          optional(:send_approval_request) => (map(), map() -> any()),
          optional(:maybe_log_drop) => (map(), map(), term() -> any()),
          optional(:start_async_task) => (map(), (-> any()) -> any())
        }

  @spec run(map(), list(), callbacks()) :: map()
  def run(state, actions, callbacks) when is_list(actions) and is_map(callbacks) do
    Enum.reduce(actions, state, fn action, acc ->
      run_action(action, acc, callbacks)
    end)
  end

  defp run_action({:execute_inbound_message, inbound}, state, callbacks) do
    callbacks.execute_inbound_message.(state, inbound)
  end

  defp run_action({:handle_inbound_message, inbound}, state, callbacks) do
    case Map.fetch(callbacks, :handle_inbound_message) do
      {:ok, handler} when is_function(handler, 2) ->
        handler.(state, inbound)

      :error ->
        if Map.has_key?(callbacks, :execute_inbound_message) do
          callbacks.execute_inbound_message.(state, inbound)
        else
          state
        end
    end
  end

  defp run_action({:handle_callback_query, callback_query}, state, callbacks) do
    _ = callbacks.handle_callback_query.(state, callback_query)
    state
  end

  defp run_action({:index_known_target, update}, state, callbacks) do
    callbacks.index_known_target.(state, update)
  end

  defp run_action({:submit_buffer, buffer}, state, callbacks) do
    callbacks.submit_buffer.(state, buffer)
  end

  defp run_action({:process_media_group, group}, state, callbacks) do
    _ = callbacks.process_media_group.(state, group)
    state
  end

  defp run_action({:send_approval_request, payload}, state, callbacks) do
    _ =
      callbacks.start_async_task.(state, fn ->
        callbacks.send_approval_request.(state, payload)
      end)

    state
  end

  defp run_action({:log_drop, inbound, reason}, state, callbacks) do
    _ = callbacks.maybe_log_drop.(state, inbound, reason)
    state
  end

  defp run_action(:noop, state, _callbacks), do: state
  defp run_action(_other, state, _callbacks), do: state
end
