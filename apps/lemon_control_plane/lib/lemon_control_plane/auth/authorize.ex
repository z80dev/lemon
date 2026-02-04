defmodule LemonControlPlane.Auth.Authorize do
  @moduledoc """
  Authorization module for the control plane.

  Implements role-based access control with the following roles:

  - `operator` - Default role for admin/operator clients
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

  When a token is provided via `auth.token`, it is validated against the
  TokenStore. If valid, the identity from the token determines the role
  and scopes. This is used for node/device connections that completed
  the challenge flow.
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

  If a token is provided, it will be validated and the identity
  extracted to determine role and scopes.
  """
  @spec from_params(map()) :: {:ok, auth_context()} | {:error, term()}
  def from_params(params) do
    token = get_in(params, ["auth", "token"])

    # If token is provided, validate it and use identity for auth
    case validate_token(token) do
      {:ok, identity} ->
        # Token is valid - derive role and scopes from identity
        {role, scopes, client_id} = identity_to_auth(identity)

        {:ok,
         %{
           role: role,
           scopes: scopes,
           token: token,
           client_id: client_id,
           identity: identity
         }}

      {:error, :invalid_token} when token != nil and token != "" ->
        # Token was provided but is invalid
        {:error, {:unauthorized, "Invalid token"}}

      {:error, :expired_token} when token != nil and token != "" ->
        # Token was provided but has expired - this is also an auth error
        {:error, {:unauthorized, "Token has expired"}}

      _ ->
        # No token or empty token - use params-based auth
        role = parse_role(params["role"])
        scopes = parse_scopes(params["scopes"], role)

        {:ok,
         %{
           role: role,
           scopes: scopes,
           token: token,
           client_id: get_in(params, ["client", "id"]),
           identity: nil
         }}
    end
  end

  # Validate token if provided
  defp validate_token(nil), do: {:error, :no_token}
  defp validate_token(""), do: {:error, :no_token}

  defp validate_token(token) do
    TokenStore.validate(token)
  end

  # Convert identity from token to role, scopes, and client_id
  defp identity_to_auth(%{"type" => "node"} = identity) do
    node_id = identity["nodeId"] || identity["node_id"]
    {:node, [:invoke, :event], node_id}
  end

  defp identity_to_auth(%{"type" => "device"} = identity) do
    device_id = identity["deviceId"] || identity["device_id"]
    {:device, [:control], device_id}
  end

  defp identity_to_auth(_identity) do
    # Unknown identity type - default to minimal permissions
    {:operator, [:read], nil}
  end

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

      is_node_only_method?(method) and ctx.role != :node ->
        {:error, {:forbidden, "Method #{method} requires node role"}}

      true ->
        {:error, {:forbidden, "Insufficient permissions for #{method}"}}
    end
  end

  @doc """
  Checks if a method requires specific role.
  """
  @spec is_node_only_method?(String.t()) :: boolean()
  def is_node_only_method?(method) do
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
        "cron.remove",
        "cron.run",
        "sessions.patch",
        "sessions.reset",
        "sessions.delete",
        "sessions.compact",
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
