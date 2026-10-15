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

  LCU's own always-allowed list (`lcu apps`) is the operator's separate, Touch
  ID–gated store and is never written from here.

  Anything other than a well-formed native-app request is cancelled (fail
  closed), and Lemon's own apps are always declined: approving the app that
  shows Lemon's approval prompts would let the agent approve itself.
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
    case native_app_request(params) do
      {:ok, app, message, offered} ->
        if lemon_host?(app),
          do: %{action: "decline"},
          else: ask(app, message, offered, context, approval_id)

      :error ->
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
  @spec lemon_host?(String.t()) :: boolean()
  def lemon_host?(app) do
    normalized = app |> String.trim() |> String.downcase()
    String.starts_with?(normalized, "org.lemonbot.") or normalized in @lemon_hosts
  end

  defp ask(app, message, offered, context, approval_id) do
    request = Map.get(context, :approval_request_fun) || (&LemonCore.ExecApprovals.request/1)

    result =
      request.(%{
        approval_id: approval_id,
        run_id: Map.get(context, :run_id),
        session_id: Map.get(context, :session_id),
        session_key: Map.get(context, :session_key),
        agent_id: Map.get(context, :agent_id),
        invocation_context_key: Map.get(context, :invocation_context_key),
        tool_call_id: Map.get(context, :tool_call_id),
        tool: @tool,
        action: %{"app" => app},
        rationale: bound(message),
        expires_in_ms: :infinity
      })

    case result do
      {:ok, :approved, scope} when scope in @once_scopes ->
        %{action: "accept", content: %{}}

      {:ok, :approved, scope} when scope in @lasting_scopes ->
        if "session" in offered,
          do: %{action: "accept", content: %{}, _meta: %{persist: "session"}},
          else: %{action: "accept", content: %{}}

      {:ok, :denied} ->
        %{action: "decline"}

      # Unknown scopes and malformed replies never authorize control.
      _other ->
        %{action: "cancel"}
    end
  catch
    kind, _reason ->
      # Authorization is never inferred from a failed approval request.
      Logger.warning("computer_use: approval request failed (#{kind})")
      %{action: "cancel"}
  end

  defp bound(message) do
    if byte_size(message) <= @max_rationale_bytes,
      do: message,
      else: String.slice(message, 0, @max_rationale_bytes) <> "…"
  end
end
