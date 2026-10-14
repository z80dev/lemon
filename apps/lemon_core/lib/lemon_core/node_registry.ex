defmodule LemonCore.NodeRegistry do
  @moduledoc """
  Live registry and targeted invocation broker for named Lemon execution nodes.

  Nodes are registered by the control-plane WebSocket connection after node
  authentication. Runtime code can then address a node by its human-readable
  name without depending on the control-plane application.

  The registry deliberately tracks live connections only. Pairing credentials
  and durable node metadata remain owned by the control plane; a node is
  executable only while its authenticated connection is registered here.
  Per-node authorized session-generation floors are retained in memory so a
  delayed handshake cannot re-register a credential generation that has
  already been superseded.
  """

  use GenServer

  alias LemonCore.JSONPayload

  @default_timeout_ms 30 * 60 * 1_000
  @default_control_timeout_ms 5_000
  @max_control_text_bytes 16 * 1_024
  @max_event_bytes 64 * 1_024
  @event_types ~w(delta started action checkpoint_created checkpoint_restored checkpoint_deleted approval_requested)
  @approval_decisions ~w(approve_once approve_session approve_agent approve_global deny)

  @type node_info :: %{
          id: String.t(),
          name: String.t(),
          pid: pid(),
          metadata: map(),
          connected_at_ms: integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), String.t(), pid(), map()) :: :ok | {:error, term()}
  def register(node_id, name, pid, metadata \\ %{})
      when is_binary(node_id) and is_binary(name) and is_pid(pid) and is_map(metadata) do
    GenServer.call(__MODULE__, {:register, node_id, String.trim(name), pid, 0, metadata, false})
  end

  @doc "Registers the authenticated connection and credential generation for a node session."
  @spec register_session(String.t(), String.t(), pid(), non_neg_integer(), map()) ::
          :ok | {:error, term()}
  def register_session(node_id, name, pid, generation, metadata \\ %{})
      when is_binary(node_id) and is_binary(name) and is_pid(pid) and
             is_integer(generation) and generation >= 0 and is_map(metadata) do
    GenServer.call(
      __MODULE__,
      {:register, node_id, String.trim(name), pid, generation, metadata, true}
    )
  end

  @spec unregister(String.t(), pid()) :: :ok
  def unregister(node_id, pid) when is_binary(node_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:unregister, node_id, pid})
  end

  @doc "Renames a live node without disturbing its connection or invocations."
  @spec rename(String.t(), String.t()) :: :ok | {:error, term()}
  def rename(node_id, name) when is_binary(node_id) and is_binary(name) do
    GenServer.call(__MODULE__, {:rename, node_id, String.trim(name)})
  end

  @spec list() :: [node_info()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec resolve(String.t()) :: {:ok, node_info()} | {:error, :not_found}
  def resolve(name_or_id) when is_binary(name_or_id) do
    GenServer.call(__MODULE__, {:resolve, String.trim(name_or_id)})
  end

  @doc "Resolves an exact durable node ID; never falls back to node names."
  def resolve_id(node_id) when is_binary(node_id) do
    GenServer.call(__MODULE__, {:resolve, {:node_id, node_id}})
  end

  @spec online?(String.t()) :: boolean()
  def online?(name_or_id) when is_binary(name_or_id) do
    match?({:ok, _node}, resolve(name_or_id))
  end

  @doc """
  Starts an invocation on a named node and returns immediately.

  The recipient receives one of:

      {:lemon_node_result, invoke_id, {:ok, result}}
      {:lemon_node_result, invoke_id, {:error, reason}}

  Live `coding_agent.run` invocations may also deliver ordered events:

      {:lemon_node_event, invoke_id, seq, event}

  Events are invocation/session-bound, start at sequence 1, and are not replayed
  after disconnect. Same-session retries at or below the accepted sequence are
  acknowledged without delivering a second event.
  """
  @spec invoke(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def invoke(name_or_id, method, args, opts \\ [])
      when is_binary(name_or_id) and is_binary(method) and is_map(args) do
    recipient = Keyword.get(opts, :recipient, self())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    max_payload_bytes =
      Keyword.get(opts, :max_payload_bytes, JSONPayload.default_max_bytes())

    GenServer.call(
      __MODULE__,
      {:invoke, String.trim(name_or_id), method, args, recipient, timeout_ms, max_payload_bytes,
       Keyword.get(opts, :expected_pid), Keyword.get(opts, :required_native_privacy_context)}
    )
  end

  @doc """
  Invokes an exact durable ID, never another node with that ID as its name.

  `:expected_pid` pins a preceding capability inspection to the current live
  connection. `required_native_privacy_context: 1` atomically requires the native
  run privacy descriptor on that actual connection before allocating or sending
  an invocation. Both failures are definite pre-dispatch admission failures.
  """
  def invoke_node(node_id, method, args, opts \\ [])
      when is_binary(node_id) and is_binary(method) and is_map(args) do
    GenServer.call(__MODULE__, {:invoke, {:node_id, node_id}, method, args,
      Keyword.get(opts, :recipient, self()), Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      Keyword.get(opts, :max_payload_bytes, JSONPayload.default_max_bytes()),
      Keyword.get(opts, :expected_pid), Keyword.get(opts, :required_native_privacy_context)})
  end

  @doc """
  Sends a bounded control operation to an active named-node invocation.

  The control is pinned to the same authenticated node connection and session
  generation that received the invocation. The recipient receives exactly one
  terminal acknowledgement:

      {:lemon_node_control_result, control_id, invoke_id, :ok}
      {:lemon_node_control_result, control_id, invoke_id, {:error, reason}}

  Returning `{:ok, control_id}` means only that the control was dispatched.
  The operation is accepted only after the destination acknowledges applying
  it to the invocation's live executor context.
  """
  @spec control(String.t(), :steer | :redirect, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def control(invoke_id, operation, text, opts \\ []) do
    recipient = Keyword.get(opts, :recipient, self())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_control_timeout_ms)

    GenServer.call(
      __MODULE__,
      {:control, invoke_id, operation, text, recipient, timeout_ms}
    )
  end

  @doc "Maximum UTF-8 byte length accepted for remote steer/redirect text."
  @spec max_control_text_bytes() :: pos_integer()
  def max_control_text_bytes, do: @max_control_text_bytes

  @spec cancel(String.t(), term()) :: :ok
  def cancel(invoke_id, reason \\ :cancelled) when is_binary(invoke_id) do
    GenServer.call(__MODULE__, {:cancel, invoke_id, reason})
  end

  @spec complete(String.t(), String.t(), term(), term()) :: :ok | {:error, term()}
  def complete(node_id, invoke_id, result, error \\ nil)
      when is_binary(node_id) and is_binary(invoke_id) do
    GenServer.call(__MODULE__, {:complete, node_id, invoke_id, result, error})
  end

  @doc "Completes an invocation only from the connection generation that received it."
  @spec complete_session(String.t(), pid(), non_neg_integer(), String.t(), term(), term()) ::
          :ok | {:error, term()}
  def complete_session(node_id, connection_pid, generation, invoke_id, result, error \\ nil)
      when is_binary(node_id) and is_pid(connection_pid) and is_integer(generation) and
             generation >= 0 and is_binary(invoke_id) do
    GenServer.call(
      __MODULE__,
      {:complete_session, node_id, connection_pid, generation, invoke_id, result, error}
    )
  end

  @doc "Accepts a bounded, ordered event from the authenticated invocation session."
  @spec event_session(String.t(), pid(), non_neg_integer(), String.t(), pos_integer(), map()) ::
          {:ok, :accepted | :duplicate} | {:error, term()}
  def event_session(node_id, connection_pid, generation, invoke_id, seq, event) do
    GenServer.call(
      __MODULE__,
      {:event_session, node_id, connection_pid, generation, invoke_id, seq, event}
    )
  end

  @doc """
  Sends an approval decision to the invocation's original live node session.

  Only the invocation recipient process may call this function. `:ok` means
  targeted dispatch, not that the destination has resolved a pending approval.
  """
  @spec approval(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def approval(invoke_id, approval_id, decision) do
    GenServer.call(__MODULE__, {:approval, invoke_id, approval_id, decision})
  end

  @doc "Completes invocation control only from the authenticated session that received it."
  @spec complete_control_session(
          String.t(),
          pid(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t(),
          boolean(),
          String.t() | nil
        ) :: :ok | {:error, term()}
  def complete_control_session(
        node_id,
        connection_pid,
        generation,
        control_id,
        invoke_id,
        run_id,
        accepted,
        reason \\ nil
      )
      when is_binary(node_id) and is_pid(connection_pid) and is_integer(generation) and
             generation >= 0 and is_binary(control_id) and is_binary(invoke_id) and
             is_binary(run_id) and is_boolean(accepted) and
             (is_nil(reason) or is_binary(reason)) do
    GenServer.call(
      __MODULE__,
      {:complete_control_session, node_id, connection_pid, generation, control_id, invoke_id,
       run_id, accepted, reason}
    )
  end

  @doc "Revokes a live connection from any credential generation older than `generation`."
  @spec revoke_session(String.t(), non_neg_integer()) :: :ok
  def revoke_session(node_id, generation)
      when is_binary(node_id) and is_integer(generation) and generation >= 0 do
    GenServer.call(__MODULE__, {:revoke_session, node_id, generation})
  end

  @doc "Pushes an event directly to one live node connection."
  @spec push(String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def push(name_or_id, event_name, payload)
      when is_binary(name_or_id) and is_binary(event_name) and is_map(payload) do
    GenServer.call(__MODULE__, {:push, String.trim(name_or_id), event_name, payload})
  end

  @doc "Routes bounded shell frames only to the recipient of a pinned open invocation."
  def shell_event_session(node_id, connection_pid, generation, invoke_id, payload) do
    GenServer.call(__MODULE__, {:shell_event_session, node_id, connection_pid, generation, invoke_id, payload})
  end

  @impl true
  def init(_opts) do
    {:ok, %{nodes: %{}, names: %{}, invocations: %{}, controls: %{}, generation_floors: %{}}}
  end

  @impl true
  def handle_call({:register, _node_id, "", _pid, _generation, _metadata, _revoke?}, _from, state) do
    {:reply, {:error, :invalid_name}, state}
  end

  def handle_call({:register, node_id, name, pid, generation, metadata, revoke?}, _from, state) do
    existing_id = Map.get(state.names, name)

    cond do
      generation < authorized_generation_floor(state, node_id) ->
        {:reply, {:error, :stale_session}, state}

      is_binary(existing_id) and existing_id != node_id ->
        {:reply, {:error, {:name_taken, name}}, state}

      true ->
        {:reply, :ok, register_node(state, node_id, name, pid, generation, metadata, revoke?)}
    end
  end

  def handle_call({:unregister, node_id, pid}, _from, state) do
    state =
      case Map.get(state.nodes, node_id) do
        %{pid: ^pid} -> remove_node(state, node_id, :disconnected)
        _ -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:rename, _node_id, ""}, _from, state) do
    {:reply, {:error, :invalid_name}, state}
  end

  def handle_call({:rename, node_id, name}, _from, state) do
    case {Map.get(state.nodes, node_id), Map.get(state.names, name)} do
      {nil, _existing_id} ->
        {:reply, {:error, :not_found}, state}

      {_node, existing_id} when is_binary(existing_id) and existing_id != node_id ->
        {:reply, {:error, {:name_taken, name}}, state}

      {node, _existing_id} ->
        renamed = %{node | name: name}

        state = %{
          state
          | nodes: Map.put(state.nodes, node_id, renamed),
            names: state.names |> Map.delete(node.name) |> Map.put(name, node_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call(:list, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.map(&public_node/1)
      |> Enum.sort_by(& &1.name)

    {:reply, nodes, state}
  end

  def handle_call({:resolve, name_or_id}, _from, state) do
    {:reply, resolve_node(state, name_or_id), state}
  end

  def handle_call({:push, name_or_id, event_name, payload}, _from, state) do
    with {:ok, _stats} <- JSONPayload.validate(payload),
         {:ok, node} <- resolve_node(state, name_or_id) do
      send(node.pid, {:node_event, event_name, payload})
      {:reply, :ok, state}
    else
      {:error, :not_found} = error -> {:reply, error, state}
      {:error, reason} -> {:reply, {:error, {:invalid_payload, reason}}, state}
    end
  end

  def handle_call({:shell_event_session, node_id, pid, generation, invoke_id, payload}, _from, state) do
    case {Map.get(state.nodes, node_id), Map.get(state.invocations, invoke_id)} do
      {%{pid: ^pid, generation: ^generation},
       %{node_id: ^node_id, node_pid: ^pid, node_generation: ^generation,
         method: "node.shell.open"} = invocation} ->
        case JSONPayload.validate(payload, max_bytes: 32_768) do
          {:ok, _} ->
            case Process.info(invocation.recipient, :message_queue_len) do
              {:message_queue_len, length} when length < 128 ->
                send(invocation.recipient, {:lemon_node_shell_event, invoke_id, payload})
                {:reply, :ok, state}
              _ -> {:reply, {:error, :slow_consumer}, state}
            end
          {:error, _} -> {:reply, {:error, :invalid_payload}, state}
        end
      _ -> {:reply, {:error, :stale_invocation}, state}
    end
  end

  def handle_call(
        {:invoke, name_or_id, method, args, recipient, timeout_ms, max_payload_bytes, expected_pid, required_privacy},
        _from,
        state
      ) do
    cond do
      not is_pid(recipient) ->
        {:reply, {:error, :invalid_recipient}, state}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:reply, {:error, :invalid_timeout}, state}

      not is_integer(max_payload_bytes) or max_payload_bytes <= 0 ->
        {:reply, {:error, :invalid_payload_limit}, state}

      not is_nil(expected_pid) and not is_pid(expected_pid) ->
        {:reply, {:error, :invalid_expected_node_pid}, state}

      not is_nil(required_privacy) and (required_privacy != 1 or method != "coding_agent.run") ->
        {:reply, {:error, :invalid_native_privacy_context_requirement}, state}

      args_error = invocation_args_error(method, args, max_payload_bytes) ->
        reason = args_error
        {:reply, {:error, {:invalid_payload, reason}}, state}

      true ->
        case resolve_dispatch_node(state, name_or_id, expected_pid, required_privacy) do
          {:ok, node} ->
            invoke_id = LemonCore.Id.uuid()
            run_id = invocation_run_id(method, args, invoke_id)
            timer_ref = Process.send_after(self(), {:invoke_timeout, invoke_id}, timeout_ms)
            recipient_ref = Process.monitor(recipient)

            invocation = %{
              id: invoke_id,
              node_id: node.id,
              node_pid: node.pid,
              node_generation: node.generation,
              recipient: recipient,
              recipient_ref: recipient_ref,
              timer_ref: timer_ref,
              method: method,
              run_id: run_id,
              latest_event_seq: 0,
              max_payload_bytes: max_payload_bytes
            }

            payload = %{
              "invokeId" => invoke_id,
              "nodeId" => node.id,
              "nodeName" => node.name,
              "method" => method,
              "args" => args,
              "timeoutMs" => timeout_ms
            }

            case JSONPayload.validate(payload, invocation_json_opts(method, max_payload_bytes)) do
              {:ok, _stats} ->
                send(node.pid, {:node_event, "node.invoke.request", payload})

                {:reply, {:ok, invoke_id},
                 %{state | invocations: Map.put(state.invocations, invoke_id, invocation)}}

              {:error, reason} ->
                cancel_invocation_monitors(invocation)
                {:reply, {:error, {:invalid_payload, reason}}, state}
            end

          {:error, :not_found} ->
            target = case name_or_id do
              {:node_id, id} -> id
              name -> name
            end
            {:reply, {:error, {:node_offline, target}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:control, invoke_id, operation, text, recipient, timeout_ms},
        _from,
        state
      ) do
    with :ok <- validate_control_request(invoke_id, operation, text, recipient, timeout_ms),
         {:ok, invocation} <- active_control_invocation(state, invoke_id),
         {:ok, node} <- active_invocation_node(state, invocation) do
      control_id = LemonCore.Id.uuid()
      timer_ref = Process.send_after(self(), {:control_timeout, control_id}, timeout_ms)
      recipient_ref = Process.monitor(recipient)

      control = %{
        id: control_id,
        invoke_id: invoke_id,
        run_id: invocation.run_id,
        operation: operation,
        node_id: invocation.node_id,
        node_pid: invocation.node_pid,
        node_generation: invocation.node_generation,
        recipient: recipient,
        recipient_ref: recipient_ref,
        timer_ref: timer_ref
      }

      payload = %{
        "controlId" => control_id,
        "invokeId" => invoke_id,
        "runId" => invocation.run_id,
        "nodeId" => node.id,
        "nodeName" => node.name,
        "operation" => Atom.to_string(operation),
        "text" => text,
        "timeoutMs" => timeout_ms
      }

      case JSONPayload.validate(payload, max_bytes: invocation.max_payload_bytes) do
        {:ok, _stats} ->
          send(node.pid, {:node_event, "node.invoke.control", payload})

          {:reply, {:ok, control_id},
           %{state | controls: Map.put(state.controls, control_id, control)}}

        {:error, reason} ->
          cancel_control_monitors(control)
          {:reply, {:error, {:invalid_payload, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, invoke_id, reason}, _from, state) do
    case Map.pop(state.invocations, invoke_id) do
      {nil, _invocations} ->
        {:reply, :ok, state}

      {invocation, invocations} ->
        cancel_invocation_monitors(invocation)
        cancel_remote_invocation(state, invoke_id, invocation, reason)
        notify(invocation, {:error, reason})

        state =
          %{state | invocations: invocations}
          |> fail_controls_for_invocation(invoke_id, :terminal)

        {:reply, :ok, state}
    end
  end

  def handle_call({:complete, node_id, invoke_id, result, error}, _from, state) do
    case Map.get(state.invocations, invoke_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{node_id: expected_node_id} when expected_node_id != node_id ->
        {:reply, {:error, :wrong_node}, state}

      invocation ->
        complete_invocation(invocation, invoke_id, result, error, state)
    end
  end

  def handle_call(
        {:complete_session, node_id, connection_pid, generation, invoke_id, result, error},
        _from,
        state
      ) do
    case {Map.get(state.nodes, node_id), Map.get(state.invocations, invoke_id)} do
      {_node, nil} ->
        {:reply, {:error, :not_found}, state}

      {_node, %{node_id: expected_node_id}} when expected_node_id != node_id ->
        {:reply, {:error, :wrong_node}, state}

      {%{pid: ^connection_pid, generation: ^generation},
       %{node_pid: ^connection_pid, node_generation: ^generation} = invocation} ->
        complete_invocation(invocation, invoke_id, result, error, state)

      _ ->
        {:reply, {:error, :stale_session}, state}
    end
  end

  def handle_call(
        {:event_session, node_id, connection_pid, generation, invoke_id, seq, event},
        _from,
        state
      ) do
    with {:ok, invocation} <-
           event_invocation(state, node_id, connection_pid, generation, invoke_id),
         :ok <- validate_event(seq, event) do
      cond do
        seq <= invocation.latest_event_seq ->
          {:reply, {:ok, :duplicate}, state}

        seq == invocation.latest_event_seq + 1 ->
          send(invocation.recipient, {:lemon_node_event, invoke_id, seq, event})
          invocation = %{invocation | latest_event_seq: seq}
          state = %{state | invocations: Map.put(state.invocations, invoke_id, invocation)}
          {:reply, {:ok, :accepted}, state}

        true ->
          {:reply, {:error, :sequence_gap}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:approval, invoke_id, approval_id, decision}, {caller, _tag}, state) do
    with {:ok, invocation} <- active_control_invocation(state, invoke_id),
         :ok <- authorize_approval_recipient(invocation, caller),
         :ok <- validate_approval(approval_id, decision),
         {:ok, node} <- active_invocation_node(state, invocation) do
      payload = %{
        "nodeId" => node.id,
        "invokeId" => invoke_id,
        "runId" => invocation.run_id,
        "approvalId" => approval_id,
        "decision" => decision
      }

      case JSONPayload.validate(payload, max_bytes: @max_event_bytes) do
        {:ok, _stats} ->
          send(node.pid, {:node_event, "node.invoke.approval", payload})
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, {:invalid_payload, payload_error_kind(reason)}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:complete_control_session, node_id, connection_pid, generation, control_id, invoke_id,
         run_id, accepted, reason},
        _from,
        state
      ) do
    case {Map.get(state.nodes, node_id), Map.get(state.controls, control_id),
          Map.get(state.invocations, invoke_id)} do
      {_node, nil, _invocation} ->
        {:reply, {:error, :not_found}, state}

      {_node, %{node_id: expected_node_id}, _invocation} when expected_node_id != node_id ->
        {:reply, {:error, :wrong_node}, state}

      {_node, %{invoke_id: expected_invoke_id}, _invocation}
      when expected_invoke_id != invoke_id ->
        {:reply, {:error, :wrong_invocation}, state}

      {_node, %{run_id: expected_run_id}, _invocation} when expected_run_id != run_id ->
        {:reply, {:error, :wrong_run}, state}

      {_node, control, nil} ->
        state = finish_control(state, control, {:error, :terminal})
        {:reply, {:error, :terminal}, state}

      {%{pid: ^connection_pid, generation: ^generation},
       %{
         node_pid: ^connection_pid,
         node_generation: ^generation,
         invoke_id: ^invoke_id,
         run_id: ^run_id
       } = control,
       %{
         node_pid: ^connection_pid,
         node_generation: ^generation,
         run_id: ^run_id
       }} ->
        result = if accepted, do: :ok, else: {:error, {:rejected, reason || "rejected"}}
        {:reply, :ok, finish_control(state, control, result)}

      _ ->
        {:reply, {:error, :stale_session}, state}
    end
  end

  def handle_call({:revoke_session, node_id, generation}, _from, state) do
    generation_floor = max(generation, authorized_generation_floor(state, node_id))

    state = %{
      state
      | generation_floors: Map.put(state.generation_floors, node_id, generation_floor)
    }

    case Map.get(state.nodes, node_id) do
      %{generation: current_generation, pid: pid} when current_generation < generation_floor ->
        send(pid, {:node_session_revoked, node_id, generation_floor})
        {:reply, :ok, remove_node(state, node_id, :credential_rotated)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:invoke_timeout, invoke_id}, state) do
    case Map.pop(state.invocations, invoke_id) do
      {nil, _invocations} ->
        {:noreply, state}

      {invocation, invocations} ->
        Process.demonitor(invocation.recipient_ref, [:flush])
        cancel_remote_invocation(state, invoke_id, invocation, :timeout)
        notify(invocation, {:error, :timeout})

        state =
          %{state | invocations: invocations}
          |> fail_controls_for_invocation(invoke_id, :terminal)

        {:noreply, state}
    end
  end

  def handle_info({:control_timeout, control_id}, state) do
    case Map.get(state.controls, control_id) do
      nil -> {:noreply, state}
      control -> {:noreply, finish_control(state, control, {:error, :timeout})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.nodes, fn {_id, node} -> node.monitor_ref == ref end) do
      {node_id, _node} ->
        {:noreply, remove_node(state, node_id, :disconnected)}

      nil ->
        state =
          Enum.reduce(state.invocations, state, fn {invoke_id, invocation}, acc ->
            if invocation.recipient_ref == ref do
              Process.cancel_timer(invocation.timer_ref)
              cancel_remote_invocation(acc, invoke_id, invocation, :recipient_down)

              acc
              |> Map.update!(:invocations, &Map.delete(&1, invoke_id))
              |> fail_controls_for_invocation(invoke_id, :recipient_down)
            else
              acc
            end
          end)

        controls =
          Enum.reduce(state.controls, state.controls, fn {control_id, control}, acc ->
            if control.recipient_ref == ref do
              Process.cancel_timer(control.timer_ref)
              Map.delete(acc, control_id)
            else
              acc
            end
          end)

        {:noreply, %{state | controls: controls}}
    end
  end

  defp resolve_node(state, {:node_id, node_id}) do
    case Map.get(state.nodes, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp resolve_node(state, name_or_id) do
    node_id = Map.get(state.names, name_or_id, name_or_id)

    case Map.get(state.nodes, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp resolve_dispatch_node(state, target, expected_pid, required_privacy) do
    with {:ok, node} <- resolve_node(state, target) do
      cond do
        not is_nil(expected_pid) and node.pid != expected_pid ->
          {:error, {:node_connection_changed, node.id}}
        required_privacy == 1 and not native_privacy_context_supported?(node.metadata) ->
          {:error, {:native_privacy_context_unsupported, node.id}}
        true -> {:ok, node}
      end
    end
  end

  defp native_privacy_context_supported?(metadata) do
    case metadata do
      %{capabilities: %{"coding_agent.run" => %{"version" => 1, "nativePrivacyContext" => %{"version" => 1}}}} -> true
      %{"capabilities" => %{"coding_agent.run" => %{"version" => 1, "nativePrivacyContext" => %{"version" => 1}}}} -> true
      _ -> false
    end
  end

  defp public_node(node) do
    Map.take(node, [:id, :name, :pid, :metadata, :connected_at_ms])
  end

  defp authorized_generation_floor(state, node_id) do
    retained_floor = Map.get(state.generation_floors, node_id, 0)

    case Map.get(state.nodes, node_id) do
      %{generation: live_generation} -> max(retained_floor, live_generation)
      nil -> retained_floor
    end
  end

  defp register_node(state, node_id, name, pid, generation, metadata, revoke?) do
    if revoke?, do: revoke_replaced_connection(state, node_id, pid, generation)
    state = remove_node(state, node_id, :reconnected)
    monitor_ref = Process.monitor(pid)

    node = %{
      id: node_id,
      name: name,
      pid: pid,
      metadata: metadata,
      generation: generation,
      connected_at_ms: System.system_time(:millisecond),
      monitor_ref: monitor_ref
    }

    %{
      state
      | nodes: Map.put(state.nodes, node_id, node),
        names: Map.put(state.names, name, node_id),
        generation_floors: Map.put(state.generation_floors, node_id, generation)
    }
  end

  defp revoke_replaced_connection(state, node_id, replacement_pid, generation) do
    case Map.get(state.nodes, node_id) do
      %{pid: pid} when pid != replacement_pid ->
        send(pid, {:node_session_revoked, node_id, generation})

      _ ->
        :ok
    end
  end

  defp complete_invocation(invocation, invoke_id, result, error, state) do
    case JSONPayload.validate(%{"result" => result, "error" => error},
           completion_json_opts(invocation.method, invocation.max_payload_bytes)) do
      {:ok, _stats} ->
        cancel_invocation_monitors(invocation)
        reply = if is_nil(error), do: {:ok, result}, else: {:error, {:remote, error}}
        notify(invocation, reply)

        state =
          %{state | invocations: Map.delete(state.invocations, invoke_id)}
          |> fail_controls_for_invocation(invoke_id, :terminal)

        {:reply, :ok, state}

      {:error, reason} ->
        cancel_invocation_monitors(invocation)
        cancel_remote_invocation(state, invoke_id, invocation, {:invalid_payload, reason})
        notify(invocation, {:error, {:invalid_remote_payload, payload_error_kind(reason)}})

        state =
          %{state | invocations: Map.delete(state.invocations, invoke_id)}
          |> fail_controls_for_invocation(invoke_id, :terminal)

        {:reply, {:error, {:invalid_payload, reason}}, state}
    end
  end

  defp remove_node(state, node_id, reason) do
    case Map.pop(state.nodes, node_id) do
      {nil, _nodes} ->
        state

      {node, nodes} ->
        Process.demonitor(node.monitor_ref, [:flush])

        {removed, kept} =
          Enum.split_with(state.invocations, fn {_invoke_id, invocation} ->
            invocation.node_id == node_id
          end)

        Enum.each(removed, fn {invoke_id, invocation} ->
          cancel_invocation_monitors(invocation)
          cancel_remote_invocation(state, invoke_id, invocation, {:node_disconnected, reason})
          notify(invocation, {:error, {:node_disconnected, reason}})
        end)

        {removed_controls, kept_controls} =
          Enum.split_with(state.controls, fn {_control_id, control} ->
            control.node_id == node_id
          end)

        Enum.each(removed_controls, fn {_control_id, control} ->
          cancel_control_monitors(control)
          notify_control(control, {:error, {:node_disconnected, reason}})
        end)

        %{
          state
          | nodes: nodes,
            names: Map.delete(state.names, node.name),
            invocations: Map.new(kept),
            controls: Map.new(kept_controls)
        }
    end
  end

  defp cancel_invocation_monitors(invocation) do
    Process.cancel_timer(invocation.timer_ref)
    Process.demonitor(invocation.recipient_ref, [:flush])
    :ok
  end

  defp notify(invocation, result) do
    send(invocation.recipient, {:lemon_node_result, invocation.id, result})
  end

  defp notify_control(control, result) do
    send(
      control.recipient,
      {:lemon_node_control_result, control.id, control.invoke_id, result}
    )
  end

  defp validate_control_request(invoke_id, operation, text, recipient, timeout_ms) do
    cond do
      not is_binary(invoke_id) or String.trim(invoke_id) == "" ->
        {:error, :invalid_invoke_id}

      operation not in [:steer, :redirect] ->
        {:error, :invalid_operation}

      not is_binary(text) or text == "" or not String.valid?(text) ->
        {:error, :invalid_text}

      byte_size(text) > @max_control_text_bytes ->
        {:error, {:text_too_large, @max_control_text_bytes}}

      not is_pid(recipient) ->
        {:error, :invalid_recipient}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:error, :invalid_timeout}

      true ->
        :ok
    end
  end

  defp event_invocation(state, node_id, connection_pid, generation, invoke_id) do
    case {Map.get(state.nodes, node_id), Map.get(state.invocations, invoke_id)} do
      {_node, nil} ->
        {:error, :terminal}

      {_node, %{node_id: expected_node_id}} when expected_node_id != node_id ->
        {:error, :wrong_node}

      {%{pid: ^connection_pid, generation: ^generation},
       %{node_pid: ^connection_pid, node_generation: ^generation}}
      when is_pid(connection_pid) and is_integer(generation) and generation >= 0 ->
        active_control_invocation(state, invoke_id)

      _ ->
        {:error, :stale_session}
    end
  end

  defp validate_event(seq, event) do
    cond do
      not is_integer(seq) or seq <= 0 ->
        {:error, :invalid_seq}

      not is_map(event) or Map.get(event, "type") not in @event_types ->
        {:error, :invalid_event_type}

      true ->
        case JSONPayload.validate(event, max_bytes: @max_event_bytes) do
          {:ok, _stats} -> :ok
          {:error, reason} -> {:error, {:invalid_payload, payload_error_kind(reason)}}
        end
    end
  end

  defp authorize_approval_recipient(%{recipient: recipient}, recipient), do: :ok
  defp authorize_approval_recipient(_invocation, _caller), do: {:error, :forbidden}

  defp validate_approval(approval_id, decision) do
    cond do
      not is_binary(approval_id) or String.trim(approval_id) == "" ->
        {:error, :invalid_approval_id}

      decision not in @approval_decisions ->
        {:error, :invalid_decision}

      true ->
        :ok
    end
  end

  defp active_control_invocation(state, invoke_id) do
    case Map.get(state.invocations, invoke_id) do
      %{method: "coding_agent.run", run_id: run_id} = invocation
      when is_binary(run_id) and run_id != "" ->
        {:ok, invocation}

      nil ->
        {:error, :terminal}

      _invocation ->
        {:error, :unsupported}
    end
  end

  defp active_invocation_node(state, invocation) do
    case Map.get(state.nodes, invocation.node_id) do
      %{pid: pid, generation: generation} = node
      when pid == invocation.node_pid and generation == invocation.node_generation ->
        {:ok, node}

      _ ->
        {:error, :node_offline}
    end
  end

  defp invocation_run_id("coding_agent.run", args, invoke_id) do
    case Map.get(args, "runId") || Map.get(args, :run_id) do
      run_id when is_binary(run_id) and run_id != "" -> run_id
      _ -> "node:#{invoke_id}"
    end
  end

  defp invocation_run_id(_method, _args, _invoke_id), do: nil

  defp finish_control(state, control, result) do
    cancel_control_monitors(control)
    notify_control(control, result)
    %{state | controls: Map.delete(state.controls, control.id)}
  end

  defp fail_controls_for_invocation(state, invoke_id, reason) do
    {removed, kept} =
      Enum.split_with(state.controls, fn {_control_id, control} ->
        control.invoke_id == invoke_id
      end)

    Enum.each(removed, fn {_control_id, control} ->
      cancel_control_monitors(control)
      notify_control(control, {:error, reason})
    end)

    %{state | controls: Map.new(kept)}
  end

  defp cancel_control_monitors(control) do
    Process.cancel_timer(control.timer_ref)
    Process.demonitor(control.recipient_ref, [:flush])
    :ok
  end

  # Bind cancellation to the same live connection that received the request.
  # A reconnect replaces the registered pid and must not receive cancellation
  # for work that belonged to the superseded socket.
  defp cancel_remote_invocation(state, invoke_id, invocation, reason) do
    case Map.get(state.nodes, invocation.node_id) do
      %{pid: pid} when pid == invocation.node_pid ->
        send(pid, {
          :node_event,
          "node.invoke.cancel",
          %{"invokeId" => invoke_id, "nodeId" => invocation.node_id, "reason" => inspect(reason)}
        })

      _ ->
        :ok
    end
  end

  defp invocation_args_error(method, args, max_payload_bytes) do
    case JSONPayload.validate(args, invocation_json_opts(method, max_payload_bytes)) do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end

  defp invocation_json_opts("coding_agent.run", max_payload_bytes),
    do: LemonCore.ToolPolicy.execution_json_opts(max_bytes: max_payload_bytes)
  defp invocation_json_opts(_method, max_payload_bytes), do: [max_bytes: max_payload_bytes]

  defp completion_json_opts("node.mcp.discover", max_payload_bytes),
    do: LemonCore.ToolPolicy.execution_json_opts(max_bytes: min(max_payload_bytes, 1_048_576))
  defp completion_json_opts(method, max_payload_bytes),
    do: invocation_json_opts(method, max_payload_bytes)

  defp payload_error_kind({kind, _detail})
       when kind in [:max_bytes, :max_depth, :max_items, :not_json_safe],
       do: kind

  defp payload_error_kind(_reason), do: :invalid
end
