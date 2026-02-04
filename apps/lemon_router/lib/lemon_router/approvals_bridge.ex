defmodule LemonRouter.ApprovalsBridge do
  @moduledoc """
  Bridge to the approvals system for tool execution gating.

  This module provides the interface for tools to request approval
  and for the control plane to resolve approval requests.

  ## Approval Scopes

  Approvals can be granted at different scopes (per parity contract):

  - `:approve_once` - Single request only (not persisted)
  - `:approve_session` - For the session (persisted per session_key)
  - `:approve_agent` - For the agent (persisted per agent_id)
  - `:approve_global` - Globally for all (persisted globally)

  ## Storage Keys

  - Global: `{tool, action_hash}`
  - Agent: `{agent_id, tool, action_hash}`
  - Session: `{session_key, tool, action_hash}`
  """

  @type approval_id :: binary()

  @doc """
  Request approval for a tool execution.

  Blocks until approval is granted, denied, or times out.

  ## Parameters

  - `:run_id` - The run requesting approval
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier (for agent-level approvals)
  - `:tool` - Tool name
  - `:action` - Action details map
  - `:rationale` - Optional rationale for the request
  - `:expires_in_ms` - Timeout in milliseconds (default: 300000)

  ## Returns

  - `{:ok, :approved, scope}` - Approved at the given scope
  - `{:ok, :denied}` - Denied
  - `{:error, :timeout}` - Request timed out
  """
  @spec request(map()) ::
          {:ok, :approved, scope :: atom()}
          | {:ok, :denied}
          | {:error, :timeout}
  def request(params) do
    run_id = params[:run_id]
    session_key = params[:session_key]
    agent_id = params[:agent_id] || extract_agent_id(session_key)
    node_id = params[:node_id]  # Optional node_id for node-level approvals
    tool = params[:tool]
    action = params[:action]
    rationale = params[:rationale]
    expires_in_ms = params[:expires_in_ms] || 300_000

    approval_id = LemonCore.Id.approval_id()

    # Check if already approved at some scope (now includes node-level)
    case check_existing_approval(tool, action, session_key, agent_id, node_id) do
      {:approved, scope} ->
        {:ok, :approved, scope}

      :not_approved ->
        # Store pending request
        pending = %{
          id: approval_id,
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id,
          tool: tool,
          action: action,
          rationale: rationale,
          requested_at_ms: LemonCore.Clock.now_ms(),
          expires_at_ms: LemonCore.Clock.now_ms() + expires_in_ms
        }

        LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

        # Emit approval requested event
        LemonCore.Telemetry.approval_requested(approval_id, tool, %{
          run_id: run_id,
          session_key: session_key,
          agent_id: agent_id
        })

        # Broadcast to bus as LemonCore.Event for proper WS delivery
        LemonCore.Bus.broadcast("exec_approvals", LemonCore.Event.new(
          :approval_requested,
          %{
            approval_id: approval_id,
            pending: pending
          },
          %{run_id: run_id, session_key: session_key, agent_id: agent_id}
        ))

        # Wait for resolution
        wait_for_resolution(approval_id, expires_in_ms)
    end
  end

  @doc """
  Resolve a pending approval request.

  ## Parameters

  - `approval_id` - The approval request ID
  - `decision` - One of:
    - `:approve_once` - Approve this specific request
    - `:approve_session` - Approve for the session
    - `:approve_agent` - Approve for the agent
    - `:approve_global` - Approve globally
    - `:deny` - Deny the request
  """
  @spec resolve(approval_id(), decision :: atom()) :: :ok
  def resolve(approval_id, decision) do
    case LemonCore.Store.get(:exec_approvals_pending, approval_id) do
      nil ->
        :ok

      pending ->
        # Remove from pending
        LemonCore.Store.delete(:exec_approvals_pending, approval_id)

        # Store approval if not denied
        if decision != :deny do
          store_approval(pending, decision)
        end

        # Emit resolved event
        LemonCore.Telemetry.approval_resolved(approval_id, decision, %{
          tool: pending.tool,
          run_id: pending.run_id
        })

        # Broadcast resolution as LemonCore.Event for proper WS delivery
        LemonCore.Bus.broadcast("exec_approvals", LemonCore.Event.new(
          :approval_resolved,
          %{
            approval_id: approval_id,
            decision: decision,
            pending: pending
          },
          %{run_id: pending.run_id, session_key: pending.session_key}
        ))

        :ok
    end
  end

  defp check_existing_approval(tool, action, session_key, agent_id, node_id \\ nil) do
    action_hash = hash_action(action)

    # Check global policy first (highest precedence)
    # Check both specific action hash and wildcard (:any) approval
    case check_global_approval(tool, action_hash) do
      {:approved, :global} ->
        {:approved, :global}

      :not_approved ->
        # Check node-level policy if node_id provided (per parity contract)
        node_result =
          if node_id do
            case check_node_approval(node_id, tool, action_hash) do
              {:approved, :node} -> {:approved, :node}
              _ -> nil
            end
          else
            nil
          end

        case node_result do
          {:approved, :node} ->
            {:approved, :node}

          _ ->
            # Check agent-level policy (keyed by agent_id, not session_key)
            case check_agent_approval(agent_id, tool, action_hash) do
              {:approved, :agent} ->
                {:approved, :agent}

              :not_approved ->
                # Check session-level policy
                case check_session_approval(session_key, tool, action_hash) do
                  {:approved, :session} ->
                    {:approved, :session}

                  :not_approved ->
                    :not_approved
                end
            end
        end
    end
  end

  # Check global approval - both specific action and wildcard
  defp check_global_approval(tool, action_hash) do
    case LemonCore.Store.get(:exec_approvals_policy, {tool, action_hash}) do
      %{approved: true} ->
        {:approved, :global}

      _ ->
        # Also check wildcard approval for the tool
        case LemonCore.Store.get(:exec_approvals_policy, {tool, :any}) do
          %{approved: true} -> {:approved, :global}
          _ -> :not_approved
        end
    end
  end

  # Check node-level approval - both specific action and wildcard
  defp check_node_approval(node_id, tool, action_hash) do
    case LemonCore.Store.get(:exec_approvals_policy_node, {node_id, tool, action_hash}) do
      %{approved: true} ->
        {:approved, :node}

      _ ->
        # Also check wildcard approval for the tool at node level
        case LemonCore.Store.get(:exec_approvals_policy_node, {node_id, tool, :any}) do
          %{approved: true} -> {:approved, :node}
          _ -> :not_approved
        end
    end
  end

  # Check agent-level approval - both specific action and wildcard
  defp check_agent_approval(agent_id, tool, action_hash) do
    case LemonCore.Store.get(:exec_approvals_policy_agent, {agent_id, tool, action_hash}) do
      %{approved: true} ->
        {:approved, :agent}

      _ ->
        # Also check wildcard approval
        case LemonCore.Store.get(:exec_approvals_policy_agent, {agent_id, tool, :any}) do
          %{approved: true} -> {:approved, :agent}
          _ -> :not_approved
        end
    end
  end

  # Check session-level approval - both specific action and wildcard
  defp check_session_approval(session_key, tool, action_hash) do
    case LemonCore.Store.get(:exec_approvals_policy_session, {session_key, tool, action_hash}) do
      %{approved: true} ->
        {:approved, :session}

      _ ->
        # Also check wildcard approval
        case LemonCore.Store.get(:exec_approvals_policy_session, {session_key, tool, :any}) do
          %{approved: true} -> {:approved, :session}
          _ -> :not_approved
        end
    end
  end

  defp store_approval(pending, decision) do
    scope =
      case decision do
        :approve_once -> :once
        :approve_session -> :session
        :approve_agent -> :agent
        :approve_global -> :global
      end

    action_hash = hash_action(pending.action)

    approval = %{
      tool: pending.tool,
      action_hash: action_hash,
      scope: scope,
      approved: true,
      approved_at_ms: LemonCore.Clock.now_ms()
    }

    case scope do
      :global ->
        LemonCore.Store.put(:exec_approvals_policy, {pending.tool, action_hash}, approval)

      :agent ->
        # Key by agent_id, not session_key (parity requirement)
        LemonCore.Store.put(
          :exec_approvals_policy_agent,
          {pending.agent_id, pending.tool, action_hash},
          approval
        )

      :session ->
        # Persist session approvals (parity requirement)
        LemonCore.Store.put(
          :exec_approvals_policy_session,
          {pending.session_key, pending.tool, action_hash},
          approval
        )

      :once ->
        # :once is not persisted
        :ok
    end
  end

  # Hash action to create a stable key
  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp hash_action(action), do: inspect(action) |> hash_action_string()

  defp hash_action_string(str) when is_binary(str) do
    :crypto.hash(:sha256, str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Extract agent_id from session_key
  defp extract_agent_id(nil), do: "default"
  defp extract_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      ["channel", _type, _transport, _account, _peer_kind, _peer_id | _] ->
        # For channel sessions, use a default agent
        "default"
      _ -> "default"
    end
  end

  defp wait_for_resolution(approval_id, timeout_ms) do
    # Subscribe to approval events
    LemonCore.Bus.subscribe("exec_approvals")

    receive do
      # Match LemonCore.Event struct with nested payload
      %LemonCore.Event{type: :approval_resolved, payload: %{approval_id: ^approval_id, decision: decision}} ->
        LemonCore.Bus.unsubscribe("exec_approvals")

        case decision do
          :deny -> {:ok, :denied}
          scope when scope in [:approve_once, :approve_session, :approve_agent, :approve_global] ->
            {:ok, :approved, scope}
        end
    after
      timeout_ms ->
        LemonCore.Bus.unsubscribe("exec_approvals")
        # Clean up expired request
        LemonCore.Store.delete(:exec_approvals_pending, approval_id)
        {:error, :timeout}
    end
  end
end
