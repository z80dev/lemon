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

  Every app is once-only by default: each action asks again, the runtime is
  never told to persist, and the request is sent with
  `LemonCore.ExecApprovals` `once_only: true`, so no stored or wildcard grant
  answers it and no decision writes a policy. Any app can show Lemon approvals
  (a browser with the Lemon Bot web client, a chat app, a terminal), so a
  lasting grant is the operator's explicit choice: only apps listed in
  `[runtime.tools.computer_use] lasting_grant_apps`
  (`LemonComputerUse.Config.lasting_grant_apps/0`) honor the decision's scope:

    * once (`:approve_once`) — accept this action only; the next action asks
      again.
    * session, agent, node or global — accept for the rest of this Lemon
      session (the runtime's own `session` persistence, keyed by the Lemon
      session id). Wider grants stay in Lemon: `ExecApprovals` answers the
      first request of later sessions from its stored grant.

  With the Chrome surface enabled the runtime also asks before it first uses
  each website. That becomes a once-only request (`once_only: true`) for the
  same tool with action `%{"origin" => origin}`: no stored or wildcard grant
  answers it and no decision writes a policy. LCU has no per-action website
  authorization, so an accepted site stays usable for the rest of that LCU
  session (the runtime remembers it); a denial declines it. The web clients of
  every chat channel Lemon delivers approvals to are declined outright.

  LCU's own always-allowed list (`lcu apps`) is the operator's separate, Touch
  ID–gated store and is never written from here.

  These requests have no time limit (`expires_in_ms: :infinity`): an operator may
  take as long as they need while the run is alive. They end with their owner
  instead. When the run or session that asked ends, `LemonCore.ExecApprovals`
  expires the pending approval at once (no grace window), the prompt is edited to
  say so, `answer/3` returns `decline`, and answering it later is refused as
  expired — an orphaned request can never grant control of an app.

  Anything other than a well-formed native-app or website request is cancelled
  (fail closed). Lemon's own apps and every local origin are always declined:
  `localhost`, `*.localhost` and any literal loopback or unspecified address,
  on any port (a loopback port may be Lemon's control plane, web UI, Lemon Bot
  backend, or a tunnel to a remote one), plus the Lemon Bot public URL and
  configured origins (`LemonComputerUse.Config.declined_origins/0`). Operating
  the surface that shows Lemon's approval prompts would let the agent approve
  itself.
  """

  require Logger
  import Bitwise, only: [band: 2]

  @tool "computer_use"
  @max_rationale_bytes 500
  @lemon_hosts ["lemon bot", "lemonbot", "lemon"]
  # Browser clients of the channels Lemon delivers approvals to (the
  # lemon_channels adapters plus Slack). A domain matches itself and every
  # subdomain; webmail hosts (the email adapter) match exactly. Generic or
  # self-hosted channel UIs belong in `declined_origins`.
  @approval_web_domains %{
    "telegram" => ~w(telegram.org t.me),
    "discord" => ~w(discord.com discordapp.com),
    "slack" => ~w(slack.com),
    "whatsapp" => ~w(whatsapp.com),
    "xmtp" => ~w(xmtp.chat converse.xyz)
  }
  @approval_webmail_hosts ~w(
    mail.google.com outlook.live.com outlook.office.com outlook.office365.com
    mail.yahoo.com app.fastmail.com mail.proton.me
  )
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
        cond do
          lemon_host?(app) ->
            %{action: "decline"}

          normalize_app(app) in LemonComputerUse.Config.lasting_grant_apps() ->
            %{"app" => app} |> ask(message, context, approval_id) |> app_response(offered)

          true ->
            %{"app" => app}
            |> ask(message, context, approval_id, once_only: true)
            |> app_response([])
        end

      {_, {:ok, origin, message}} ->
        if lemon_origin?(origin),
          do: %{action: "decline"},
          else:
            %{"origin" => origin}
            |> ask(message, context, approval_id, once_only: true)
            |> origin_response()

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
        LemonComputerUse.Config.origin_of(uri) == [origin]

      _ ->
        false
    end
  end

  @doc false
  @spec lemon_origin?(String.t()) :: boolean()
  def lemon_origin?(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) and host != "" ->
        local_host?(host) or approval_web_client?(host) or
          origin in LemonComputerUse.Config.declined_origins()

      # Fail closed: an origin without a host is never a safe target.
      _ ->
        true
    end
  end

  # Every local spelling, on any port: Lemon's ports are configurable,
  # persisted per install, and forwarded through tunnels, so no port list can
  # be complete. A hostname is resolved and declined when any address it
  # resolves to is local. DNS can change after this check (rebinding); the
  # check narrows, not closes, that window.
  defp local_host?(host) do
    host = host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")
    host = String.trim_trailing(host, ".")

    cond do
      host == "localhost" or String.ends_with?(host, ".localhost") ->
        true

      LemonCore.LoopbackListener.literal_loopback?(host) ->
        true

      true ->
        case :inet.parse_address(String.to_charlist(host)) do
          {:ok, address} -> local_address?(address)
          {:error, _} -> resolves_local?(host)
        end
    end
  end

  defp resolves_local?(host) do
    case resolve(host) do
      {:ok, addresses} -> Enum.any?(addresses, &local_address?/1)
      # A resolver that cannot answer in time is not proof of safety.
      :timeout -> true
      :error -> false
    end
  end

  @resolve_timeout_ms 2_000

  defp resolve(host) do
    resolver =
      Application.get_env(:lemon_computer_use, :resolver, &default_resolve/1)

    task =
      Task.async(fn ->
        try do
          resolver.(host)
        catch
          _, _ -> :error
        end
      end)

    case Task.yield(task, @resolve_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      {:ok, _} -> :error
      _ -> :timeout
    end
  end

  defp default_resolve(host) do
    charlist = String.to_charlist(host)

    for family <- [:inet, :inet6],
        {:ok, addresses} <- [:inet.getaddrs(charlist, family)],
        address <- addresses,
        do: address
  end

  # Loopback, unspecified, link-local, IPv4-mapped forms of those, and every
  # address of this machine's interfaces (a LAN address reaches Lemon's
  # listeners too).
  defp local_address?({127, _, _, _}), do: true
  defp local_address?({0, _, _, _}), do: true
  defp local_address?({169, 254, _, _}), do: true
  defp local_address?({0, 0, 0, 0, 0, 0, 0, n}) when n in [0, 1], do: true
  defp local_address?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: true

  defp local_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: local_address?({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  defp local_address?(address), do: address in interface_addresses()

  defp interface_addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {_name, opts} <- interfaces, {:addr, address} <- opts, do: address

      _ ->
        []
    end
  end

  @doc false
  @spec approval_web_client?(String.t()) :: boolean()
  def approval_web_client?(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    host in @approval_webmail_hosts or
      Enum.any?(Map.values(@approval_web_domains), fn domains ->
        Enum.any?(domains, &(host == &1 or String.ends_with?(host, "." <> &1)))
      end)
  end

  @doc false
  @spec lemon_host?(String.t()) :: boolean()
  def lemon_host?(app) do
    normalized = app |> String.trim() |> String.downcase()
    String.starts_with?(normalized, "org.lemonbot.") or normalized in @lemon_hosts
  end

  defp normalize_app(app), do: app |> String.trim() |> String.downcase()

  defp ask(action, message, context, approval_id, opts \\ []) do
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
      # No clock deadline: the owning run or session ending expires the request
      # (LemonCore.ExecApprovals.expire_owner/1), never an elapsed timer.
      expires_in_ms: :infinity,
      once_only: Keyword.get(opts, :once_only, false)
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
