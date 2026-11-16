defmodule CodingAgent.Session.ResponsesTransport do
  @moduledoc false

  alias LemonAi.Providers.OpenAIResponsesWebSocket

  # This handle is volatile session state, never a journal entry or a caller's
  # transport. Invocation rebinding preserves it while replacing run authority.
  def prepare(state, model, options) do
    provider_options =
      (Map.get(options, :provider_options) || %{})
      |> Map.drop([:responses_transport, "responses_transport"])

    if model.api in [:openai_responses, :openai_codex_responses] and
         provider_options[:responses_websocket] == true do
      {state, pid} = transport_for(state, model)
      {state, %{options | provider_options: Map.put(provider_options, :responses_transport, pid)}}
    else
      {reset(state), %{options | provider_options: provider_options}}
    end
  end

  def switch_model(state, model) do
    if identity(state.model) == identity(model), do: state, else: reset(state)
  end

  def reset(state) do
    case Keyword.get(Map.get(state, :tool_opts) || [], :responses_transport) do
      %{pid: pid, model: model} = transport when not is_nil(model) ->
        if Process.alive?(pid), do: OpenAIResponsesWebSocket.reset(pid)
        put_transport(state, %{transport | model: nil})

      _ ->
        state
    end
  end

  defp transport_for(state, model) do
    model_identity = identity(model)
    transport = Keyword.get(state.tool_opts, :responses_transport)

    case transport do
      %{pid: pid, model: previous} when is_pid(pid) ->
        if Process.alive?(pid) do
          if previous != nil and previous != model_identity,
            do: OpenAIResponsesWebSocket.reset(pid)

          {put_transport(state, %{pid: pid, model: model_identity}), pid}
        else
          start_transport(state, model_identity)
        end

      _ ->
        start_transport(state, model_identity)
    end
  end

  defp start_transport(state, model_identity) do
    {:ok, pid} = OpenAIResponsesWebSocket.start_link(owner: self())
    {put_transport(state, %{pid: pid, model: model_identity}), pid}
  end

  defp put_transport(state, transport),
    do: %{state | tool_opts: Keyword.put(state.tool_opts, :responses_transport, transport)}

  defp identity(model), do: {model.provider, model.api, model.id}
end
