defmodule LemonComputerUse.Approval do
  @moduledoc """
  Answers the computer-use runtime's native-app approval requests with Lemon's
  own approval plane.

  On macOS the original runtime asks, per app, before the agent may control it
  (an MCP elicitation). LCU's shared client has already declined apps that host
  the agent (the terminal or app this runtime runs under). What is left is
  forwarded here and becomes an ordinary `LemonCore.ExecApprovals` request for
  tool `"computer_use"` with action `%{"app" => app}`, carrying the run,
  session, agent and invocation context of the tool call that triggered it. The
  operator answers it wherever Lemon approvals are answered; session, agent and
  global grants are remembered by `ExecApprovals` and answer later requests for
  the same app without asking.

  The runtime asks again for every action under an "allow once" answer, so
  the Lemon decision's scope decides the answer:

    * once (`:approve_once`) — accept this action only; the next action asks
      again.
    * session, agent, node or global — accept for the rest of this Lemon
      session (the runtime's own `session` persistence, keyed by the Lemon
      session id). Wider grants stay in Lemon: `ExecApprovals` answers the
      first request of later sessions from its stored grant.

  With the Chrome surface enabled the runtime also asks before it first uses
  each website. That becomes a request for the same tool with action
  `%{"origin" => origin}`. Any approval scope accepts the site: the runtime
  itself remembers a site decision for the rest of the LCU session, so even an
  "approve once" covers that site for the session; a denial declines it.

  LCU's own always-allowed list (`lcu apps`) is the operator's separate, Touch
  ID–gated store and is never written from here.

  Anything other than a well-formed native-app or website request is cancelled
  (fail closed). Lemon's own apps and Lemon's own local web and control-plane
  origins are always declined: operating the surface that shows Lemon's
  approval prompts would let the agent approve itself.
  """

  require Logger

  @tool "computer_use"
  @max_rationale_bytes 500
  @lemon_hosts ["lemon bot", "lemonbot", "lemon"]
  @once_scopes [:once, :approve_once]
  @lasting_scopes [
    :session,
    :agent,
    :node,
    :global,
    :approve_session,
    :approve_agent,
    :approve_global
  ]

  @doc """
  Decide one elicitation. Blocks until the operator answers; returns the MCP
  elicitation result to send back to the runtime.
  """
  @spec answer(map(), map(), String.t()) :: map()
  def answer(params, context, approval_id) do
    case {native_app_request(params), browser_origin_request(params)} do
      {{:ok, app, message, offered}, _} ->
        if lemon_host?(app),
          do: %{action: "decline"},
          else: %{"app" => app} |> ask(message, context, approval_id) |> app_response(offered)

      {_, {:ok, origin, message}} ->
        if lemon_origin?(origin),
          do: %{action: "decline"},
          else: %{"origin" => origin} |> ask(message, context, approval_id) |> origin_response()

      _ ->
        %{action: "cancel"}
    end
  end

  @doc "Withdraw a pending approval whose request the runtime abandoned."
  @spec cancel(String.t()) :: :ok
  def cancel(approval_id) do
    LemonCore.ExecApprovals.cancel(approval_id, "computer use request withdrawn")
    :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec native_app_request(map()) :: {:ok, String.t(), String.t(), [String.t()]} | :error
  def native_app_request(%{"mode" => "form", "message" => message} = params)
      when is_binary(message) and message != "" do
    meta = Map.get(params, "_meta") || %{}
    schema = Map.get(params, "requestedSchema") || %{}

    with "computer-use" <- meta["connector_id"],
         "mcp_tool_call" <- meta["codex_approval_kind"],
         %{"app" => app} when is_binary(app) and app != "" <- meta["tool_params"],
         "object" <- schema["type"],
         properties when properties == %{} <- Map.get(schema, "properties", %{}) do
      offered = if is_list(meta["persist"]), do: meta["persist"], else: []
      {:ok, app, message, offered}
    else
      _ -> :error
    end
  end

  def native_app_request(_params), do: :error

  @doc false
  @spec browser_origin_request(map()) :: {:ok, String.t(), String.t()} | :error
  def browser_origin_request(%{"message" => message} = params)
      when is_binary(message) and message != "" do
    meta = Map.get(params, "_meta") || %{}
    schema = Map.get(params, "requestedSchema") || %{}

    with mode when mode in [nil, "form"] <- Map.get(params, "mode"),
         "browser-use" <- meta["connector_id"],
         "mcp_tool_call" <- meta["codex_approval_kind"],
         "access_browser_origin" <- meta["tool_name"],
         origin when is_binary(origin) <- meta["origin"],
         true <- canonical_origin?(origin),
         "object" <- schema["type"],
         properties when properties == %{} <- Map.get(schema, "properties", %{}),
         required when required in [nil, []] <- Map.get(schema, "required") do
      {:ok, origin, message}
    else
      _ -> :error
    end
  end

  def browser_origin_request(_params), do: :error

  # Exactly `scheme://host[:port]` for http(s), as a browser serializes an
  # origin: no credentials, path, query or fragment, default ports omitted.
  defp canonical_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, ""] ->
        origin == serialize_origin(uri)

      _ ->
        false
    end
  end

  defp serialize_origin(%URI{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    default = if scheme == "https", do: 443, else: 80
    port = if port in [nil, default], do: "", else: ":" <> Integer.to_string(port)
    scheme <> "://" <> host <> port
  end

  @doc false
  @spec lemon_origin?(String.t()) :: boolean()
  def lemon_origin?(origin) do
    %URI{host: host, port: port} = URI.parse(origin)

    (host in ["localhost", "127.0.0.1", "::1"] and port in lemon_ports()) or
      origin in LemonComputerUse.Config.declined_origins()
  end

  # Lemon's control plane and web UI, plus the Lemon Bot web client's
  # development server (4081), on loopback.
  defp lemon_ports do
    env = LemonCore.Runtime.Env.resolve()
    [env.control_port, env.web_port, 4081]
  rescue
    _ -> [4040, 4080, 4081]
  end

  @doc false
  @spec lemon_host?(String.t()) :: boolean()
  def lemon_host?(app) do
    normalized = app |> String.trim() |> String.downcase()
    String.starts_with?(normalized, "org.lemonbot.") or normalized in @lemon_hosts
  end

  defp ask(action, message, context, approval_id) do
    request = Map.get(context, :approval_request_fun) || (&LemonCore.ExecApprovals.request/1)

    request.(%{
      approval_id: approval_id,
      run_id: Map.get(context, :run_id),
      session_id: Map.get(context, :session_id),
      session_key: Map.get(context, :session_key),
      agent_id: Map.get(context, :agent_id),
      invocation_context_key: Map.get(context, :invocation_context_key),
      tool_call_id: Map.get(context, :tool_call_id),
      tool: @tool,
      action: action,
      rationale: bound(message),
      expires_in_ms: :infinity
    })
  catch
    kind, _reason ->
      # Authorization is never inferred from a failed approval request.
      Logger.warning("computer_use: approval request failed (#{kind})")
      {:error, :approval_unavailable}
  end

  defp app_response({:ok, :approved, scope}, _offered) when scope in @once_scopes,
    do: %{action: "accept", content: %{}}

  defp app_response({:ok, :approved, scope}, offered) when scope in @lasting_scopes do
    if "session" in offered,
      do: %{action: "accept", content: %{}, _meta: %{persist: "session"}},
      else: %{action: "accept", content: %{}}
  end

  defp app_response(result, _offered), do: denied_or_cancel(result)

  defp origin_response({:ok, :approved, scope})
       when scope in @once_scopes or scope in @lasting_scopes,
       do: %{action: "accept", content: %{}}

  defp origin_response(result), do: denied_or_cancel(result)

  defp denied_or_cancel({:ok, :denied}), do: %{action: "decline"}
  # Unknown scopes, errors and malformed replies never authorize control.
  defp denied_or_cancel(_result), do: %{action: "cancel"}

  defp bound(message) do
    if byte_size(message) <= @max_rationale_bytes,
      do: message,
      else: String.slice(message, 0, @max_rationale_bytes) <> "…"
  end
end
