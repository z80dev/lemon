defmodule LemonControlPlane.Auth.Authorize do
  @moduledoc """
  Authorization module for the control plane.

  Implements role-based access control with the following roles:

  - `operator` - Admin/operator clients authenticated by the configured operator
    token; the WebSocket boundary may explicitly opt direct loopback peers into
    a legacy tokenless compatibility path
  - `node` - Role for paired nodes (browser extensions, etc.)
  - `device` - Role for paired devices

  Each role has associated scopes that control method access.

  ## Operator Scopes

  - `operator.admin` - Administrative operations (config, wizard, install, etc.)
  - `operator.read` - Read-only operations (status, list, get, etc.)
  - `operator.write` - Write operations (send, agent, chat, etc.)
  - `operator.approvals` - Approval management (exec.approvals.*, exec.approval.*)
  - `operator.pairing` - Node/device pairing (node.pair.*)

  ## Node Scopes

  - `node.invoke` - Receive and respond to invocations
  - `node.event` - Send events

  ## Device Scopes

  - `device.control` - Control operations

  ## Method Authorization

  Methods declare their required scopes. A connection must have at least one
  matching scope to call a method. Some methods are public (no scopes required).

  ## Token-Based Authentication

  When a token is provided via `auth.token`, it is first compared in constant
  time with the configured control-plane operator token. Otherwise it is
  validated against the TokenStore and the stored identity determines the role
  and scopes. Unknown stored identity types fail closed instead of inheriting an
  operator role.
  """

  alias LemonControlPlane.Auth.TokenStore

  @type role :: :operator | :node | :device
  @type scope ::
          :admin
          | :read
          | :write
          | :approvals
          | :pairing
          | :invoke
          | :event
          | :control

  @type auth_context :: %{
          role: role(),
          scopes: [scope()],
          token: String.t() | nil,
          client_id: String.t() | nil,
          identity: map() | nil
        }

  @doc """
  Creates a new auth context from connection parameters.

  If a token is provided, it will be validated and the identity extracted to
  determine role and scopes. `:local?` defaults to true for direct in-process
  callers; the WebSocket boundary always supplies the actual peer classification.
  """
  @spec from_params(map()) :: {:ok, auth_context()} | {:error, term()}
  def from_params(params), do: from_params(params, local?: true)

  @spec from_params(map(), keyword()) :: {:ok, auth_context()} | {:error, term()}
  def from_params(params, opts) do
    token = get_in(params, ["auth", "token"])
    requested_role = parse_role(params["role"])
    local? = Keyword.get(opts, :local?, true)
    configured_operator_token = operator_token()

    cond do
      requested_role == :operator and
          secure_token_match?(token, configured_operator_token) ->
        operator_context(params)

      present?(token) ->
        authenticate_session_token(token, requested_role, configured_operator_token)

      requested_role != :operator ->
        {:error, {:unauthorized, "A valid #{requested_role} session token is required"}}

      present?(configured_operator_token) ->
        {:error, {:unauthorized, "Operator token is required"}}

      local? ->
        operator_context(params)

      true ->
        {:error,
         {:unauthorized,
          "Operator authentication is required; configure LEMON_CONTROL_PLANE_OPERATOR_TOKEN"}}
    end
  end

  defp authenticate_session_token(token, requested_role, configured_operator_token) do
    case TokenStore.validate(token) do
      {:ok, identity} ->
        with {:ok, {role, scopes, client_id}} <- identity_to_auth(identity) do
          {:ok,
           %{
             role: role,
             scopes: scopes,
             token: nil,
             client_id: client_id,
             identity: identity
           }}
        end

      {:error, :expired_token} ->
        {:error, {:unauthorized, "Token has expired"}}

      {:error, :invalid_token}
      when requested_role == :operator and is_binary(configured_operator_token) ->
        {:error, {:unauthorized, "Operator token is invalid"}}

      {:error, :invalid_token} ->
        {:error, {:unauthorized, "Invalid token"}}
    end
  end

  defp operator_context(params) do
    {:ok,
     %{
       role: :operator,
       scopes: parse_scopes(params["scopes"], :operator),
       token: nil,
       client_id: get_in(params, ["client", "id"]),
       identity: nil
     }}
  end

  # Convert identity from token to role, scopes, and client_id
  defp identity_to_auth(%{"type" => "node"} = identity) do
    node_id = identity["nodeId"] || identity["node_id"]
    {:ok, {:node, [:invoke, :event], node_id}}
  end

  defp identity_to_auth(%{"type" => "device"} = identity) do
    device_id = identity["deviceId"] || identity["device_id"]
    {:ok, {:device, [:control], device_id}}
  end

  defp identity_to_auth(_identity) do
    {:error, {:unauthorized, "Unsupported token identity"}}
  end

  defp operator_token do
    (Application.get_env(:lemon_control_plane, :operator_token) ||
       System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN"))
    |> normalize_token()
  end

  # Hashing first keeps the secure comparison input length fixed and avoids
  # leaking the configured token length through an early size check.
  defp secure_token_match?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end

  defp secure_token_match?(_left, _right), do: false

  defp normalize_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Creates a default operator auth context with all scopes.
  """
  @spec default_operator() :: auth_context()
  def default_operator do
    %{
      role: :operator,
      scopes: [:admin, :read, :write, :approvals, :pairing],
      token: nil,
      client_id: nil
    }
  end

  @doc """
  Creates a node auth context.
  """
  @spec node_context(String.t()) :: auth_context()
  def node_context(node_id) do
    %{
      role: :node,
      scopes: [:invoke, :event],
      token: nil,
      client_id: node_id
    }
  end

  @doc """
  Checks if the auth context is authorized for the given method.

  Returns `:ok` if authorized, `{:error, reason}` otherwise.
  """
  @spec authorize(auth_context(), String.t(), [scope()]) :: :ok | {:error, term()}
  def authorize(_ctx, _method, []) do
    # Public method, no scopes required
    :ok
  end

  def authorize(%{scopes: ctx_scopes} = ctx, method, required_scopes) do
    # Check if any required scope is present in context
    has_scope = Enum.any?(required_scopes, fn scope -> scope in ctx_scopes end)

    cond do
      has_scope ->
        :ok

      node_only_method?(method) and ctx.role != :node ->
        {:error, {:forbidden, "Method #{method} requires node role"}}

      true ->
        {:error, {:forbidden, "Insufficient permissions for #{method}"}}
    end
  end

  @doc """
  Checks if a method requires specific role.
  """
  @spec node_only_method?(String.t()) :: boolean()
  def node_only_method?(method) do
    method in ["node.invoke.result", "node.event", "skills.bins"]
  end

  @doc """
  Returns the required scopes for a method.

  Methods are categorized as:
  - Public: No scopes required (health, status)
  - Read: Requires :read scope (list, get operations)
  - Write: Requires :write scope (send, agent, chat operations)
  - Admin: Requires :admin scope (config, install, cron management)
  - Approvals: Requires :approvals scope (exec.approvals.*, exec.approval.*)
  - Pairing: Requires :pairing scope (node.pair.*)
  """
  @spec required_scopes(String.t()) :: [scope()]
  def required_scopes(method) do
    cond do
      public_method?(method) ->
        []

      admin_method?(method) ->
        [:admin]

      approvals_method?(method) ->
        [:approvals]

      pairing_method?(method) ->
        [:pairing]

      node_method?(method) ->
        [:invoke, :event]

      write_method?(method) ->
        [:write]

      true ->
        [:read]
    end
  end

  # Public methods - no auth required
  defp public_method?(method) do
    method in ["health", "connect"]
  end

  # Admin methods - require operator.admin
  defp admin_method?(method) do
    String.starts_with?(method, "config.") or
      String.starts_with?(method, "wizard.") or
      method in [
        "channels.logout",
        "skills.install",
        "skills.update",
        "cron.add",
        "cron.update",
        "cron.pause",
        "cron.resume",
        "cron.abort",
        "cron.remove",
        "cron.run",
        "sessions.patch",
        "sessions.metadata.patch",
        "sessions.prune",
        "sessions.reset",
        "sessions.delete",
        "sessions.compact",
        "sessions.heartbeat",
        "update.run"
      ]
  end

  # Approval methods - require operator.approvals
  defp approvals_method?(method) do
    String.starts_with?(method, "exec.approvals.") or
      String.starts_with?(method, "exec.approval.")
  end

  # Pairing methods - require operator.pairing
  defp pairing_method?(method) do
    String.starts_with?(method, "node.pair.") or
      String.starts_with?(method, "device.pair.")
  end

  # Node-only methods
  defp node_method?(method) do
    method in ["node.invoke.result", "node.event"]
  end

  # Write methods - require operator.write
  defp write_method?(method) do
    method in [
      "send",
      "agent",
      "agent.wait",
      "agent.inbox.send",
      "agent.endpoints.set",
      "agent.endpoints.delete",
      "chat.send",
      "chat.abort",
      "wake",
      "set-heartbeats",
      "talk.mode",
      "node.invoke",
      "browser.request"
    ]
  end

  defp parse_role("node"), do: :node
  defp parse_role("device"), do: :device
  defp parse_role(_), do: :operator

  defp parse_scopes(nil, :operator), do: [:admin, :read, :write, :approvals, :pairing]
  defp parse_scopes(nil, :node), do: [:invoke, :event]
  defp parse_scopes(nil, :device), do: [:control]

  defp parse_scopes(scopes, _role) when is_list(scopes) do
    scopes
    |> Enum.map(&parse_scope/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_scopes(_, role), do: parse_scopes(nil, role)

  defp parse_scope("operator.admin"), do: :admin
  defp parse_scope("operator.read"), do: :read
  defp parse_scope("operator.write"), do: :write
  defp parse_scope("operator.approvals"), do: :approvals
  defp parse_scope("operator.pairing"), do: :pairing
  defp parse_scope("node.invoke"), do: :invoke
  defp parse_scope("node.event"), do: :event
  defp parse_scope("device.control"), do: :control
  defp parse_scope("admin"), do: :admin
  defp parse_scope("read"), do: :read
  defp parse_scope("write"), do: :write
  defp parse_scope(_), do: nil
end
