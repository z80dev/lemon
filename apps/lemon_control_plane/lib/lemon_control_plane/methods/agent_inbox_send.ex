defmodule LemonControlPlane.Methods.AgentInboxSend do
  @moduledoc """
  Handler for the `agent.inbox.send` control-plane method.

  Sends an inbox message to an agent with optional endpoint/session targeting.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.inbox.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    prompt = get_param(params, "prompt")
    agent_id = get_param(params, "agentId") || "default"

    cond do
      not (is_binary(prompt) and String.trim(prompt) != "") ->
        {:error, {:invalid_request, "prompt is required", nil}}

      not (is_binary(agent_id) and String.trim(agent_id) != "") ->
        {:error, {:invalid_request, "agentId must be a non-empty string", nil}}

      true ->
        case LemonRouter.send_to_agent(agent_id, prompt, build_send_opts(params)) do
          {:ok, result} ->
            {:ok,
             %{
               "runId" => result.run_id,
               "sessionKey" => result.session_key,
               "selector" => selector_label(result.selector),
               "fanoutCount" => result.fanout_count || 0
             }}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to send inbox message", inspect(reason)}}
        end
    end
  end

  defp build_send_opts(params) do
    session_selector = parse_session_selector(params)

    [
      session: session_selector,
      queue_mode: parse_queue_mode(get_param(params, "queueMode")),
      engine_id: get_param(params, "engineId"),
      model: get_param(params, "model"),
      cwd: get_param(params, "cwd"),
      tool_policy: get_param(params, "toolPolicy"),
      meta: normalize_map(get_param(params, "meta")),
      source: "control_plane",
      account_id: get_param(params, "accountId"),
      peer_kind: get_param(params, "peerKind"),
      to: get_param(params, "to") || get_param(params, "endpoint") || get_param(params, "route"),
      deliver_to: get_param(params, "deliverTo")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp parse_session_selector(params) do
    cond do
      get_param(params, "sessionKey") in [:latest, :new] ->
        get_param(params, "sessionKey")

      is_binary(get_param(params, "sessionKey")) ->
        get_param(params, "sessionKey")

      get_param(params, "session") in [:latest, :new] ->
        get_param(params, "session")

      is_binary(get_param(params, "session")) ->
        get_param(params, "session")

      get_param(params, "sessionTag") in [:latest, :new] ->
        get_param(params, "sessionTag")

      is_binary(get_param(params, "sessionTag")) ->
        get_param(params, "sessionTag")

      true ->
        :latest
    end
  end

  defp parse_queue_mode(nil), do: :followup
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode
  defp parse_queue_mode(_), do: :followup

  defp selector_label(selector) when is_atom(selector), do: Atom.to_string(selector)
  defp selector_label(selector) when is_binary(selector), do: "explicit"
  defp selector_label(_), do: "unknown"

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
