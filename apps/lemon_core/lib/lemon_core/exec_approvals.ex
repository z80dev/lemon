defmodule LemonCore.ExecApprovals do
  @moduledoc """
  Tool execution approvals (shared).

  This module is the shared implementation for tool execution gating. It is
  intentionally placed in `:lemon_core` so other apps (coding_agent, gateway,
  channels, control_plane) can request/resolve approvals without depending on
  `:lemon_router`.

  ## Approval Scopes

  Approvals can be granted at different scopes:

  - `:approve_once` - Single request only (not persisted)
  - `:approve_session` - For the session (persisted per session_key)
  - `:approve_agent` - For the agent (persisted per agent_id)
  - `:approve_global` - Globally for all (persisted globally)

  ## Storage Keys

  - Global: `{tool, action_hash}`
  - Agent: `{agent_id, tool, action_hash}`
  - Session: `{session_key, tool, action_hash}`

  With a trusted `invocation_context_key`, session/agent identity in these
  keys is `{:invocation_context, public_identity, invocation_context_key}`.
  There is no fallback to an unscoped identity; nil-context native callers
  retain their existing keys. The private key never appears in wire receipts.

  ## Owner expiry

  A pending approval belongs to the run (`:run_id`) and native session
  (`:session_id`) that asked for it. When that owner ends nobody can act on the
  answer any more, so the approval expires at once: there is no grace window.
  `expire_owner/1` replaces each of the owner's pending records with a redacted
  `:expired` receipt, wakes a live waiter as denied and installs no policy. A
  later `resolve/3` returns `{:error, :expired}`; it can never approve. Run end
  is observed through the `LemonCore.Store` finalize-run hook and session end
  from the native session's shutdown, both routed by `LemonCore.ExecApprovalExpiry`.
  This covers requests with no time limit (`expires_in_ms: :infinity`) too.
  """

  alias LemonCore.Events.{ApprovalPending, ApprovalRequested, ApprovalResolved}
  alias LemonCore.ExecApprovalExpiry
  alias LemonCore.ExecApprovalStore

  @type approval_id :: binary()

  @doc """
  Request approval for a tool execution.

  Blocks until approval is granted, denied, or times out.

  ## Parameters

  - `:run_id` - The run requesting approval
  - `:session_id` - Optional native CodingAgent session ID
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier (for agent-level approvals)
  - `:invocation_context_key` - Optional trusted private principal/policy context.
    Session and agent grants are isolated by this exact key; context-owned runs
    never fall back to legacy shared-session/agent grants. Global/node admin
    grants remain intentionally independent.
  - `:node_id` - Optional node identifier (for node-level approvals)
  - `:tool` - Tool name
  - `:action` - Action details map
  - `:rationale` - Optional rationale for the request
  - `:expires_in_ms` - Timeout in milliseconds (default: no timeout). An
    approval with no timeout still expires when its run or session ends.
  - `:approval_id` - Optional caller-allocated approval id. Callers that may
  have to cancel the prompt before it resolves (for example, a dispatch that
  can be killed while waiting) allocate the id up front so they can name it to
  `cancel/2` with no registration race.

  ## Returns
  - `{:ok, :approved, scope}` - Approved at the given scope
  - `{:ok, :denied}` - Denied, cancelled by its owner, or expired because its
    run or session ended (see "Owner expiry")
  - `{:error, :timeout}` - Request timed out. The timeout competes through
    the same exact-record atomic transition as `resolve/3` and `cancel/2`.
    A losing timeout emits no events and installs no policy.
  """
  @spec request(map()) ::
          {:ok, :approved, scope :: atom()}
          | {:ok, :denied}
          | {:error, atom()}
  def request(params) when is_map(params) do
    run_id = params[:run_id]
    session_id = params[:session_id]
    session_key = params[:session_key]
    agent_id = params[:agent_id] || extract_agent_id(session_key)
    node_id = params[:node_id]
    invocation_context_key = params[:invocation_context_key]
    tool = params[:tool]
    action = params[:action]
    rationale = params[:rationale]
    # Tool calls should not enforce timeouts by default.
    expires_in_ms = params[:expires_in_ms] || :infinity

    approval_id =
      case params[:approval_id] do
        id when is_binary(id) and id != "" -> id
        _other -> LemonCore.Id.approval_id()
      end

    case check_existing_approval(
           tool,
           action,
           session_key,
           agent_id,
           node_id,
           invocation_context_key
         ) do
      {:approved, scope} ->
        {:ok, :approved, scope}

      :not_approved ->
        # Subscribe before publishing the request so a fast resolve can't race us.
        LemonCore.Bus.subscribe("exec_approvals")

        expires_at_ms =
          case expires_in_ms do
            :infinity -> nil
            ms when is_integer(ms) -> LemonCore.Clock.now_ms() + ms
            _ -> nil
          end

        pending =
          ApprovalPending.new(%{
            id: approval_id,
            run_id: run_id,
            session_id: session_id,
            session_key: session_key,
            agent_id: agent_id,
            owner_runtime_id: ExecApprovalExpiry.runtime_id(),
            owner_session_pid: ExecApprovalExpiry.session_owner(session_id),
            invocation_context_key: invocation_context_key,
            tool: tool,
            tool_call_id: params[:tool_call_id],
            action: action,
            rationale: rationale,
            requested_at_ms: LemonCore.Clock.now_ms(),
            expires_at_ms: expires_at_ms
          })

        case ExecApprovalStore.put_pending_new(approval_id, pending) do
          :ok ->
            LemonCore.Telemetry.approval_requested(approval_id, tool, %{
              run_id: run_id,
              session_id: session_id,
              session_key: session_key,
              agent_id: agent_id
            })

            record_approval_event(:approval_requested, pending, %{
              approval_id: approval_id,
              tool: tool,
              action_type: action_type(action),
              action_hash: hash_action(action),
              rationale_present?: is_binary(rationale) and rationale != "",
              expires_at_ms: expires_at_ms
            })

            LemonCore.Bus.broadcast(
              "exec_approvals",
              LemonCore.Event.new(
                :approval_requested,
                ApprovalRequested.new(%{approval_id: approval_id, pending: pending}),
                %{
                  run_id: run_id,
                  session_id: session_id,
                  session_key: session_key,
                  agent_id: agent_id
                }
              )
            )

            wait_for_resolution(approval_id, pending, expires_in_ms)

          {:error, reason} ->
            LemonCore.Bus.unsubscribe("exec_approvals")
            {:error, if(reason == :exists, do: :already_pending, else: :store_unavailable)}
        end
    end
  end

  @doc """
  Cancel a pending approval that will never be decided by a user.

  Atomically replaces the exact pending record with a redacted cancellation
  receipt, wakes its waiter as denied, and installs no policy. A competing
  resolution or timeout has exactly one winner. A losing cancellation is a
  no-op; retained terminal records remain available to verified resolvers.

  ## Returns

    * `:ok` — this call took the pending record and cancelled it
    * `{:error, :not_pending}` — nothing was pending under `approval_id`
      (unknown, already resolved, or already cancelled); a no-op
  """
  @spec cancel(approval_id(), binary() | nil) :: :ok | {:error, :not_pending | :store_unavailable}
  def cancel(approval_id, reason \\ nil) when is_binary(approval_id) do
    with {:ok, pending} when not is_nil(pending) <- ExecApprovalStore.fetch_pending(approval_id),
         :ok <- retain_terminal(approval_id, pending, :cancelled, :cancelled) do
      record_approval_event(:approval_cancelled, pending, %{
        approval_id: approval_id,
        tool: pending.tool,
        reason: reason
      })

      LemonCore.Telemetry.approval_resolved(approval_id, :cancelled, %{
        tool: pending.tool,
        run_id: pending.run_id
      })

      LemonCore.Bus.broadcast(
        "exec_approvals",
        LemonCore.Event.new(
          :approval_resolved,
          ApprovalResolved.new(%{
            approval_id: approval_id,
            decision: :cancelled,
            pending: pending
          }),
          %{
            run_id: pending.run_id,
            session_id: Map.get(pending, :session_id),
            session_key: pending.session_key
          }
        )
      )

      :ok
    else
      {:ok, nil} -> {:error, :not_pending}
      {:error, :mismatch} -> {:error, :not_pending}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  @doc """
  Expire every pending approval owned by a run or session that has ended.

  `{:run, run_id}` matches the request's `:run_id`; `{:session, session_id}` its
  native `:session_id`. Each match is atomically replaced by a redacted
  `:expired` receipt, its waiter (if it is still alive) wakes as denied, and no
  policy is installed. A competing resolution, timeout or cancellation has
  exactly one winner; a losing expiry leaves the winner's record alone. Expiry
  is immediate: there is no grace window. Afterwards `resolve/3` returns
  `{:error, :expired}` and `LemonCore.ExecApprovalStore.fetch_pending/1` returns
  `{:ok, nil}`.

  Listeners see `:approval_resolved` with `decision: :expired`. Time-based
  expiry keeps `decision: :timeout`.

  ## Returns

    * `{:ok, count}` — the number of approvals this call expired (0 is normal)
    * `{:error, :store_unavailable}` — pending requests could not be read, or an
      expiry could not be recorded (that approval stays pending and unapproved)
    * `{:error, :invalid_owner}` — the owner is not a non-empty run or session id
  """
  @spec expire_owner({:run | :session, binary()}) ::
          {:ok, non_neg_integer()} | {:error, :store_unavailable | :invalid_owner}
  def expire_owner({kind, id}) when kind in [:run, :session] and is_binary(id) and id != "" do
    with {:ok, rows} <- ExecApprovalStore.fetch_pending_list() do
      results =
        for {approval_id, pending} <- rows, owned_by?(pending, approval_id, kind, id) do
          expire_pending(approval_id, pending, kind)
        end

      if :error in results,
        do: {:error, :store_unavailable},
        else: {:ok, Enum.count(results, &(&1 == :expired))}
    end
  end

  def expire_owner(_owner), do: {:error, :invalid_owner}

  @doc false
  def reconcile_runtime do
    with {:ok, rows} <- ExecApprovalStore.fetch_pending_list() do
      Enum.reduce_while(rows, {:ok, 0}, fn {id, pending}, {:ok, count} ->
        case recovery_owner_gone?(pending) do
          {:ok, true} ->
            case expire_pending(id, pending, owner_kind(pending)) do
              :expired -> {:cont, {:ok, count + 1}}
              :lost -> {:cont, {:ok, count}}
              :error -> {:halt, {:error, :store_unavailable}}
            end

          {:ok, false} ->
            {:cont, {:ok, count}}

          {:error, _} ->
            {:halt, {:error, :store_unavailable}}
        end
      end)
    end
  end

  defp recovery_owner_gone?(pending) do
    if orphaned_runtime?(pending) or dead_session?(pending) do
      {:ok, true}
    else
      case Map.get(pending, :run_id) do
        id when is_binary(id) and id != "" ->
          case LemonCore.RunStore.fetch(id) do
            {:ok, %{summary: summary}} when is_map(summary) -> {:ok, true}
            {:ok, _} -> {:ok, false}
            {:error, _} = error -> error
          end

        _ ->
          {:ok, false}
      end
    end
  end

  defp orphaned_runtime?(pending),
    do: Map.get(pending, :owner_runtime_id) != ExecApprovalExpiry.runtime_id()

  defp dead_session?(pending) do
    case Map.get(pending, :owner_session_pid) do
      pid when is_pid(pid) -> node(pid) == node() and not Process.alive?(pid)
      _ -> false
    end
  end

  defp owner_kind(%{run_id: id}) when is_binary(id) and id != "", do: :run
  defp owner_kind(_pending), do: :session

  defp owned_by?(%{id: approval_id} = pending, approval_id, :run, run_id),
    do: Map.get(pending, :run_id) == run_id

  defp owned_by?(%{id: approval_id} = pending, approval_id, :session, session_id),
    do: Map.get(pending, :session_id) == session_id

  defp owned_by?(_pending, _approval_id, _kind, _id), do: false

  defp expire_pending(approval_id, pending, kind) do
    case retain_terminal(approval_id, pending, :expired, :expired) do
      :ok ->
        emit_expiry(approval_id, pending, kind)
        :expired

      {:error, :mismatch} ->
        :lost

      {:error, _} ->
        :error
    end
  end

  defp emit_expiry(approval_id, pending, kind) do
    record_approval_event(:approval_expired, pending, %{
      approval_id: approval_id,
      tool: pending.tool,
      owner: Atom.to_string(kind)
    })

    LemonCore.Telemetry.approval_resolved(approval_id, :expired, %{
      tool: pending.tool,
      run_id: pending.run_id
    })

    LemonCore.Bus.broadcast(
      "exec_approvals",
      LemonCore.Event.new(
        :approval_resolved,
        ApprovalResolved.new(%{approval_id: approval_id, decision: :expired, pending: pending}),
        %{
          run_id: pending.run_id,
          session_id: Map.get(pending, :session_id),
          session_key: pending.session_key
        }
      )
    )
  end

  @doc """
  Resolve an exact pending approval and return a verified resolution receipt.

  `expected_session_key` and `expected_run_id` bind the request's owner identity.
  `expected_pending` binds the entire preview snapshot. The owner compares and
  replaces the exact validated record atomically; a replacement request is never
  consumed. Expiry is checked after the claim and before installing any policy.

  Decisions are `:approve_once`, `:approve_session`, `:approve_agent`,
  `:approve_global`, or `:deny`. Success is `{:ok, receipt}` with approval/run/
  session identity, actual `decision`, `outcome` (`:approved` or `:denied`),
  `resolved_at_ms`, and `replayed`. A replay succeeds only with both exact
  expected identities, the same decision, and a retained completed receipt.
  Replays never emit events or install policy again. Completed IDs are not reused.

  Errors distinguish `:not_found`, `:mismatch`, `:expired`, `:cancelled`,
  `:conflict`, `:already_resolved`, `:resolution_in_progress`,
  `:invalid_decision`, `:invalid_binding`, and `:store_unavailable`.
  Missing retained state is never treated as proof of an earlier resolution.
  """
  @spec resolve(approval_id(), atom(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resolve(approval_id, decision, opts \\ [])

  def resolve(approval_id, decision, opts)
      when is_binary(approval_id) and is_list(opts) and
             decision in [:approve_once, :approve_session, :approve_agent, :approve_global, :deny] do
    with :ok <- validate_bindings(opts),
         {:ok, record} <- ExecApprovalStore.fetch_record(approval_id) do
      case record do
        nil ->
          {:error, :not_found}

        %{resolution: receipt} ->
          replay_resolution(approval_id, receipt, decision, opts)

        %{id: ^approval_id, tool: tool, action: _, session_key: _, run_id: _, agent_id: _} =
            pending
        when is_binary(tool) ->
          with :ok <- match_pending(pending, opts),
               :ok <- ExecApprovalExpiry.ensure_ready() do
            claim = %{resolution: resolution_receipt(pending, decision, :resolving)}

            case ExecApprovalStore.transition(approval_id, pending, claim) do
              :ok -> resolve_claim(approval_id, pending, decision, claim)
              {:error, :mismatch} -> lost_resolution(approval_id, decision, opts)
              {:error, _} -> {:error, :store_unavailable}
            end
          end

        _ ->
          {:error, :mismatch}
      end
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_decision}

  defp validate_bindings(opts) do
    if Enum.all?([:expected_session_key, :expected_run_id], fn key ->
         case Keyword.fetch(opts, key) do
           :error -> true
           {:ok, value} -> is_binary(value) and value != ""
         end
       end) do
      :ok
    else
      {:error, :invalid_binding}
    end
  end

  defp match_pending(pending, opts) do
    with :ok <- match_identity(pending, opts) do
      case Keyword.fetch(opts, :expected_pending) do
        :error -> :ok
        {:ok, ^pending} -> :ok
        _ -> {:error, :mismatch}
      end
    end
  end

  defp match_identity(record, opts) do
    if Enum.all?(
         [{:expected_session_key, :session_key}, {:expected_run_id, :run_id}],
         fn {option, field} ->
           case Keyword.fetch(opts, option) do
             :error -> true
             {:ok, expected} -> Map.get(record, field) == expected
           end
         end
       ) do
      :ok
    else
      {:error, :mismatch}
    end
  end

  defp resolve_claim(approval_id, pending, decision, claim) do
    cond do
      (not is_nil(Map.get(pending, :owner_runtime_id)) and orphaned_runtime?(pending)) or
          dead_session?(pending) ->
        result = finish_resolution(approval_id, claim, :expired, :expired)
        emit_expiry(approval_id, pending, owner_kind(pending))
        if match?({:ok, _}, result), do: {:error, :expired}, else: result

      expired?(pending) ->
        result = finish_resolution(approval_id, claim, :expired, :timeout)
        emit_approval_timeout(approval_id, pending)
        if match?({:ok, _}, result), do: {:error, :expired}, else: result

      decision == :deny ->
        result = finish_resolution(approval_id, claim, :denied, decision)
        emit_resolution(approval_id, pending, decision)
        result

      true ->
        case store_approval(pending, decision) do
          :ok ->
            result = finish_resolution(approval_id, claim, :approved, decision)
            # Without a retained, verified completion, execution stays denied.
            emitted_decision = if match?({:ok, _}, result), do: decision, else: :cancelled
            emit_resolution(approval_id, pending, emitted_decision)
            result

          _ ->
            _ = finish_resolution(approval_id, claim, :cancelled, :cancelled)
            emit_resolution(approval_id, pending, :cancelled)
            {:error, :store_unavailable}
        end
    end
  end

  defp finish_resolution(approval_id, %{resolution: receipt} = claim, outcome, decision) do
    completed = %{
      receipt
      | outcome: outcome,
        decision: decision,
        resolved_at_ms: LemonCore.Clock.now_ms()
    }

    case ExecApprovalStore.transition(approval_id, claim, %{resolution: completed}) do
      :ok -> {:ok, public_receipt(completed, false)}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp resolution_receipt(pending, decision, outcome) do
    %{
      approval_id: pending.id,
      session_key: Map.get(pending, :session_key),
      run_id: Map.get(pending, :run_id),
      decision: decision,
      outcome: outcome,
      resolved_at_ms: LemonCore.Clock.now_ms(),
      pending_hash: :crypto.hash(:sha256, :erlang.term_to_binary(pending))
    }
  end

  defp retain_terminal(approval_id, pending, outcome, decision) do
    ExecApprovalStore.transition(
      approval_id,
      pending,
      %{resolution: resolution_receipt(pending, decision, outcome)}
    )
  end

  defp lost_resolution(approval_id, decision, opts) do
    case ExecApprovalStore.fetch_record(approval_id) do
      {:ok, %{resolution: receipt}} -> replay_resolution(approval_id, receipt, decision, opts)
      {:ok, nil} -> {:error, :not_found}
      {:ok, _} -> {:error, :mismatch}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  defp replay_resolution(
         approval_id,
         %{
           approval_id: stored_id,
           session_key: _,
           run_id: _,
           outcome: _,
           decision: _,
           resolved_at_ms: timestamp,
           pending_hash: digest
         } = receipt,
         decision,
         opts
       )
       when stored_id == approval_id and is_integer(timestamp) and is_binary(digest) do
    with :ok <- match_identity(receipt, opts),
         :ok <- match_receipt_snapshot(receipt, opts) do
      cond do
        receipt.outcome == :expired ->
          {:error, :expired}

        receipt.outcome == :cancelled ->
          {:error, :cancelled}

        receipt.decision != decision ->
          {:error, :conflict}

        receipt.outcome == :resolving ->
          {:error, :resolution_in_progress}

        not (Keyword.has_key?(opts, :expected_session_key) and
                 Keyword.has_key?(opts, :expected_run_id)) ->
          {:error, :already_resolved}

        receipt.outcome == :denied and receipt.decision == :deny ->
          {:ok, public_receipt(receipt, true)}

        receipt.outcome == :approved and
            receipt.decision in [:approve_once, :approve_session, :approve_agent, :approve_global] ->
          {:ok, public_receipt(receipt, true)}

        true ->
          {:error, :store_unavailable}
      end
    end
  end

  defp replay_resolution(_, _, _, _), do: {:error, :store_unavailable}

  defp match_receipt_snapshot(receipt, opts) do
    case Keyword.fetch(opts, :expected_pending) do
      :error ->
        :ok

      {:ok, pending} when is_map(pending) ->
        if :crypto.hash(:sha256, :erlang.term_to_binary(pending)) == receipt.pending_hash,
          do: :ok,
          else: {:error, :mismatch}

      _ ->
        {:error, :mismatch}
    end
  end

  defp public_receipt(receipt, replayed) do
    receipt |> Map.delete(:pending_hash) |> Map.put(:replayed, replayed)
  end

  defp expired?(pending) do
    case Map.get(pending, :expires_at_ms) do
      nil -> false
      expires when is_integer(expires) -> expires <= LemonCore.Clock.now_ms()
      _ -> true
    end
  end

  defp emit_resolution(approval_id, pending, decision) do
    LemonCore.Telemetry.approval_resolved(approval_id, decision, %{
      tool: pending.tool,
      run_id: pending.run_id
    })

    record_approval_event(:approval_resolved, pending, %{
      approval_id: approval_id,
      tool: pending.tool,
      decision: to_string(decision),
      scope: decision_scope(decision),
      approved?: decision not in [:deny, :cancelled]
    })

    LemonCore.Bus.broadcast(
      "exec_approvals",
      LemonCore.Event.new(
        :approval_resolved,
        ApprovalResolved.new(%{approval_id: approval_id, decision: decision, pending: pending}),
        %{
          run_id: pending.run_id,
          session_id: Map.get(pending, :session_id),
          session_key: pending.session_key
        }
      )
    )

    :ok
  end

  defp check_existing_approval(
         tool,
         action,
         session_key,
         agent_id,
         node_id,
         invocation_context_key
       ) do
    action_hash = hash_action(action)
    session_scope = policy_identity(session_key, invocation_context_key)
    agent_scope = policy_identity(agent_id, invocation_context_key)

    # Check scopes in priority order: global > node > agent > session
    checks = [
      {:global, fn -> ExecApprovalStore.get_global_policy(tool, action_hash) end,
       fn -> ExecApprovalStore.get_global_policy(tool, :any) end},
      if(node_id,
        do:
          {:node, fn -> ExecApprovalStore.get_node_policy(node_id, tool, action_hash) end,
           fn -> ExecApprovalStore.get_node_policy(node_id, tool, :any) end}
      ),
      {:agent, fn -> ExecApprovalStore.get_agent_policy(agent_scope, tool, action_hash) end,
       fn -> ExecApprovalStore.get_agent_policy(agent_scope, tool, :any) end},
      {:session, fn -> ExecApprovalStore.get_session_policy(session_scope, tool, action_hash) end,
       fn -> ExecApprovalStore.get_session_policy(session_scope, tool, :any) end}
    ]

    checks
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(:not_approved, fn {scope, exact_fn, wildcard_fn} ->
      check_approval_level(scope, exact_fn, wildcard_fn)
    end)
  end

  defp check_approval_level(scope, exact_fn, wildcard_fn) do
    case exact_fn.() do
      %{approved: true} ->
        {:approved, scope}

      _ ->
        case wildcard_fn.() do
          %{approved: true} -> {:approved, scope}
          _ -> nil
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
    invocation_context_key = Map.get(pending, :invocation_context_key)

    approval = %{
      tool: pending.tool,
      action_hash: action_hash,
      scope: scope,
      approved: true,
      approved_at_ms: LemonCore.Clock.now_ms()
    }

    case scope do
      :global ->
        ExecApprovalStore.put_global_policy(pending.tool, action_hash, approval)

      :agent ->
        ExecApprovalStore.put_agent_policy(
          policy_identity(pending.agent_id, invocation_context_key),
          pending.tool,
          action_hash,
          approval
        )

      :session ->
        ExecApprovalStore.put_session_policy(
          policy_identity(pending.session_key, invocation_context_key),
          pending.tool,
          action_hash,
          approval
        )

      :once ->
        :ok
    end
  end

  defp policy_identity(identity, nil), do: identity

  defp policy_identity(identity, invocation_context_key),
    do: {:invocation_context, identity, invocation_context_key}

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

  defp extract_agent_id(nil), do: "default"

  defp extract_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] ->
        agent_id

      ["channel", _type, _transport, _account, _peer_kind, _peer_id | _] ->
        "default"

      _ ->
        "default"
    end
  end

  defp wait_for_resolution(approval_id, pending, :infinity) do
    wait_for_resolution_until(approval_id, pending, :infinity)
  end

  defp wait_for_resolution(approval_id, pending, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    wait_for_resolution_until(
      approval_id,
      pending,
      System.monotonic_time(:millisecond) + timeout_ms
    )
  end

  defp wait_for_resolution(approval_id, pending, _timeout_ms) do
    wait_for_resolution_until(approval_id, pending, :infinity)
  end

  defp wait_for_resolution_until(approval_id, pending, deadline_or_infinity) do
    receive do
      %LemonCore.Event{
        type: :approval_requested,
        payload: %{approval_id: ^approval_id}
      } ->
        wait_for_resolution_until(approval_id, pending, deadline_or_infinity)

      %LemonCore.Event{
        type: :approval_requested,
        payload: %{pending: %{id: ^approval_id}}
      } ->
        wait_for_resolution_until(approval_id, pending, deadline_or_infinity)

      %LemonCore.Event{
        type: :approval_resolved,
        payload: %{approval_id: ^approval_id, decision: decision}
      } ->
        LemonCore.Bus.unsubscribe("exec_approvals")

        case decision do
          :deny ->
            {:ok, :denied}

          # An owner cancel (`cancel/2`) resolves the waiter like a denial:
          # nobody granted the approval, so the gated call must not run.
          :cancelled ->
            {:ok, :denied}

          # The owning run or session ended (`expire_owner/1`): nobody can use
          # an answer any more, so the gated call is denied, never approved.
          :expired ->
            {:ok, :denied}

          :timeout ->
            {:error, :timeout}

          scope
          when scope in [:approve_once, :approve_session, :approve_agent, :approve_global] ->
            {:ok, :approved, scope}
        end
    after
      wait_remaining(deadline_or_infinity) ->
        LemonCore.Bus.unsubscribe("exec_approvals")

        # Compare the waiter's original snapshot, not just its ID. Neither a
        # winning resolver nor a replacement invocation can be timed out here.
        case retain_terminal(approval_id, pending, :expired, :timeout) do
          :ok ->
            emit_approval_timeout(approval_id, pending)
            {:error, :timeout}

          {:error, :mismatch} ->
            {:error, :timeout}

          {:error, _} ->
            {:error, :store_unavailable}
        end
    end
  end

  defp wait_remaining(:infinity), do: :infinity

  defp wait_remaining(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  # Called only by the winner of the exact-record timeout transition.
  defp record_approval_timeout(approval_id, pending) do
    record_approval_event(:approval_timed_out, pending, %{
      approval_id: approval_id,
      tool: pending.tool,
      action_type: action_type(pending.action),
      action_hash: hash_action(pending.action)
    })
  end

  defp emit_approval_timeout(approval_id, pending) do
    record_approval_timeout(approval_id, pending)

    LemonCore.Telemetry.approval_resolved(approval_id, :timeout, %{
      tool: pending.tool,
      run_id: pending.run_id
    })

    LemonCore.Bus.broadcast(
      "exec_approvals",
      LemonCore.Event.new(
        :approval_resolved,
        ApprovalResolved.new(%{
          approval_id: approval_id,
          decision: :timeout,
          pending: pending
        }),
        %{
          run_id: pending.run_id,
          session_id: Map.get(pending, :session_id),
          session_key: pending.session_key
        }
      )
    )
  end

  # Introspection is best-effort observability: a rejected payload must not
  # fail the approval transition that already happened (same posture as
  # `LemonCore.Checkpoint`), so the record outcome is deliberately dropped.
  defp record_approval_event(event_type, pending, payload) do
    _ =
      LemonCore.Introspection.record(event_type, payload,
        run_id: pending.run_id,
        session_key: pending.session_key,
        agent_id: pending.agent_id
      )

    :ok
  end

  defp action_type(action) when is_map(action) do
    action[:type] || action["type"]
  end

  defp action_type(_), do: nil

  defp decision_scope(:approve_once), do: "once"
  defp decision_scope(:approve_session), do: "session"
  defp decision_scope(:approve_agent), do: "agent"
  defp decision_scope(:approve_global), do: "global"
  defp decision_scope(:deny), do: "deny"
  defp decision_scope(decision), do: to_string(decision)
end
