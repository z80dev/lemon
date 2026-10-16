defmodule CodingAgent.ExecutionNode.Worker do
  @moduledoc """
  Native worker for a named Lemon execution node.

  The worker authenticates to a controller, accepts targeted native runs and
  destination MCP discovery/profile synchronization, and keeps slow services in
  supervised tasks bound to their invocation and this worker. Native runs execute
  through `CodingAgent.Executor` without forwarding the node selector into the
  local session, preventing recursive remote routing.
  Incoming execution capabilities are intersected with the destination-local
  `:execution_capabilities` ceiling before a session starts.
  """

  use GenServer

  require Logger

  alias CodingAgent.ExecutionNode.{Codec, Socket, TokenStore}
  alias CodingAgent.Executor.RemoteEventCodec
  alias LemonCore.{Bus, ExecApprovals, ExecutionContext, ToolPolicy}
  alias LemonGateway.ExecutionRequest
  alias LemonMemory.{ContextScope, Document, Ingest, Project}

  @protocol_version 1
  @execution_protocol_version 2
  @max_control_text_bytes 16 * 1_024
  @max_pending_events 64
  @approval_decisions %{
    "approve_once" => :approve_once,
    "approve_session" => :approve_session,
    "approve_agent" => :approve_agent,
    "approve_global" => :approve_global,
    "deny" => :deny
  }
  @host_io_methods [
    "node.host.info",
    "node.fs.list",
    "node.fs.stat",
    "node.fs.read",
    "node.fs.write",
    "node.fs.mkdir",
    "node.fs.move",
    "node.fs.delete.preview",
    "node.fs.delete",
    "node.secrets.set",
    "node.secrets.list",
    "node.secrets.delete",
    "node.secrets.receipt"
  ]
  @shell_methods ["node.shell.open", "node.shell.input", "node.shell.resize", "node.shell.close"]
  @process_methods ["node.process.run", "node.process.get", "node.process.cancel"]
  @provider_methods Enum.map(
                      LemonCore.ProviderManagement.operations(),
                      &("node.providers.management." <> &1)
                    )
  @process_capability %{
    "version" => 1,
    "maxStdinBytes" => 1_048_576,
    "maxOutputBytes" => 1_048_576,
    "maxTimeoutMs" => 1_800_000,
    "maxArgvBytes" => 131_072
  }
  @capabilities %{
    "coding_agent.run" => %{
      "version" => @execution_protocol_version,
      "nativePrivacyContext" => %{"version" => 1},
      "executionContext" => %{"version" => 1}
    },
    "node.invoke.event" => %{"version" => @protocol_version, "maxBytes" => 65_536},
    "node.enrollment" => %{"version" => 1, "inviteCodes" => true, "repairInvites" => true},
    "node.mcp.discover" => %{"version" => @protocol_version},
    "node.profile.sync" => %{"version" => @protocol_version},
    "node.profile.sync.status" => %{"version" => @protocol_version},
    "node.profile.paths" => %{"version" => @protocol_version},
    "memory.list" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.search" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.get" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.add" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.delete" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.prepare" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.snapshot" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.validate" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.preview" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.apply" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.status" => %{"version" => @protocol_version, "contextVersion" => 1},
    "memory.transfer.inspect" => %{"version" => @protocol_version, "contextVersion" => 1},
    "node.invoke.control" => %{
      "version" => @protocol_version,
      "operations" => ["steer", "redirect"],
      "maxTextBytes" => @max_control_text_bytes
    },
    "node.invoke.cancel" => true
  }

  @doc "Declared protocol capabilities, shared by pairing and installed-runtime inspection."
  def capabilities do
    @capabilities
    |> Map.merge(
      Map.new(
        @host_io_methods ++
          @shell_methods ++
          @provider_methods ++
          ["node.capabilities.get", "node.runtime.features"],
        &{&1, true}
      )
    )
    |> Map.merge(Map.new(@process_methods, &{&1, @process_capability}))
  end

  @doc "Live runtime compatibility, without asserting provider login or OS grants."
  def runtime_features do
    capabilities = capabilities()

    CodingAgent.ExecutionNode.Features.snapshot(capabilities)
    |> Map.put("capabilities", capabilities)
    |> Map.put(
      "nativePrivacyContext",
      get_in(capabilities, ["coding_agent.run", "nativePrivacyContext"])
    )
  end

  defstruct [
    :name,
    :controller,
    :default_cwd,
    :socket,
    :allowed_roots,
    :invite_code,
    :socket_module,
    :socket_opts,
    :socket_mode,
    :executor_module,
    :mcp_discovery_module,
    :profile_sync_module,
    :task_supervisor,
    :memory_ingest_server,
    :token_store_module,
    :token_store_opts,
    :notify_pid,
    :node_id,
    :expected_node_id,
    :requested_node_id,
    :recovery_node_id,
    :recovery_token,
    :repair,
    :pairing_stage,
    :pairing_id,
    :max_payload_bytes,
    shells: %{},
    process_tasks: %{},
    execution_capabilities: :all,
    invocations: %{},
    run_refs: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, name} <- nonempty(Keyword.get(opts, :node_name), :invalid_node_name),
         {:ok, controller} <-
           controller_url(
             Keyword.get(opts, :controller),
             Keyword.get(opts, :allow_insecure_controller, false)
           ),
         {:ok, default_cwd} <- existing_directory(Keyword.get(opts, :cwd, File.cwd!())),
         {:ok, state} <- build_state(opts, name, controller, default_cwd),
         {:ok, state} <- connect_initial(state, opts) do
      :ok = Bus.subscribe("exec_approvals")
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp build_state(opts, name, controller, default_cwd) do
    {:ok,
     %__MODULE__{
       name: name,
       controller: controller,
       default_cwd: default_cwd,
       allowed_roots: Keyword.get(opts, :allowed_roots, [System.user_home!()]),
       invite_code: Keyword.get(opts, :invite_code),
       socket_module: Keyword.get(opts, :socket_module, Socket),
       socket_opts: Keyword.get(opts, :socket_opts, []),
       executor_module: Keyword.get(opts, :executor_module, CodingAgent.Executor),
       mcp_discovery_module: Keyword.get(opts, :mcp_discovery_module, LemonSkills.McpDiscovery),
       profile_sync_module:
         Keyword.get(opts, :profile_sync_module, CodingAgent.ExecutionNode.ProfileSync),
       task_supervisor: Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor),
       memory_ingest_server: Keyword.get(opts, :memory_ingest_server, Ingest),
       token_store_module: Keyword.get(opts, :token_store_module, TokenStore),
       token_store_opts: Keyword.get(opts, :token_store_opts, []),
       notify_pid: Keyword.get(opts, :notify_pid),
       requested_node_id: Keyword.get(opts, :node_id),
       repair: Keyword.get(opts, :repair, false),
       max_payload_bytes: LemonCore.JSONPayload.default_max_bytes(),
       execution_capabilities: Keyword.get(opts, :execution_capabilities, :all)
     }}
  end

  defp connect_initial(state, opts) do
    if Keyword.get(opts, :pair, false) or is_binary(state.invite_code) do
      with {:ok, state} <-
             if(is_binary(state.invite_code),
               do: {:ok, state},
               else: prepare_pairing_identity(state)
             ) do
        connect_pairing(state, Keyword.get(opts, :operator_token))
      end
    else
      with {:ok, token, expected_node_id} <- resolve_token(state, Keyword.get(opts, :token)) do
        connect_authenticated(state, token, expected_node_id)
      end
    end
  end

  defp connect_pairing(state, operator_token) do
    connect_params =
      if is_binary(state.invite_code) do
        %{
          "role" => "enrollment",
          "auth" => %{"inviteCode" => state.invite_code},
          "client" => %{"id" => "lemon-execution-node-pair:#{state.name}"}
        }
      else
        %{"role" => "operator", "client" => %{"id" => "lemon-execution-node-pair:#{state.name}"}}
        |> maybe_put_auth(operator_token)
      end

    start_socket(state, :pairing, connect_params)
  end

  defp connect_authenticated(state, token, expected_node_id) do
    connect_params = %{
      "auth" => %{"token" => token},
      "client" => %{"id" => "lemon-execution-node:#{state.name}"},
      "capabilities" => capabilities()
    }

    with {:ok, state} <- start_socket(state, :node, connect_params) do
      {:ok, %{state | expected_node_id: expected_node_id}}
    end
  end

  defp start_socket(state, mode, connect_params) do
    opts =
      state.socket_opts
      |> Keyword.merge(owner: self(), url: state.controller, connect_params: connect_params)

    case state.socket_module.start_link(opts) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket, socket_mode: mode, pairing_stage: nil}}

      {:error, reason} ->
        {:error, {:socket_start_failed, reason}}
    end
  end

  @impl true
  def handle_info(
        {:execution_node_socket, socket, {:connected, _hello}},
        %{socket: socket, socket_mode: :pairing, invite_code: code, pairing_stage: stage} = state
      )
      when is_binary(code) and not is_nil(stage) do
    {:stop, {:pairing_failed, :outcome_unknown}, state}
  end

  def handle_info(
        {:execution_node_socket, socket, {:connected, hello}},
        %{socket: socket} = state
      ) do
    case state.socket_mode do
      :pairing ->
        state = update_payload_limit(state, hello)
        state = resume_pairing(state)
        notify(state, {:status, :pairing})
        {:noreply, state}

      :node ->
        state = update_payload_limit(state, hello)
        node_id = get_in(hello, ["auth", "clientId"])

        cond do
          not is_binary(node_id) or node_id == "" ->
            {:stop, :missing_authenticated_node_id, state}

          is_binary(state.expected_node_id) and state.expected_node_id != node_id ->
            {:stop,
             {:authenticated_node_id_mismatch,
              %{expected: state.expected_node_id, actual: node_id}}, state}

          true ->
            notify(state, {:status, :online, node_id})
            {:noreply, %{state | node_id: node_id}}
        end
    end
  end

  def handle_info(
        {:execution_node_socket, socket, {:response, tag, result}},
        %{socket: socket} = state
      ) do
    handle_socket_response(tag, result, state)
  end

  def handle_info(
        {:execution_node_socket, socket, {:event, event, payload}},
        %{socket: socket, socket_mode: :node} = state
      ) do
    handle_node_event(event, payload, state)
  end

  def handle_info(
        {:execution_node_socket, socket, {:disconnected, _reason}},
        %{socket: socket, socket_mode: :pairing, invite_code: code} = state
      )
      when is_binary(code) do
    {:stop, {:pairing_failed, :outcome_unknown}, state}
  end

  def handle_info(
        {:execution_node_socket, socket, {:disconnected, reason}},
        %{socket: socket} = state
      ) do
    state = cancel_all_invocations(state)
    notify(state, {:status, :reconnecting})
    Logger.warning("Execution node connection lost; reconnecting: #{safe_reason(reason)}")
    {:noreply, %{state | node_id: nil}}
  end

  def handle_info(
        {:execution_node_socket, socket, {:authentication_error, error}},
        %{socket: socket} = state
      ) do
    notify(state, {:status, :authentication_error})

    send(
      self(),
      {:stop_after_authentication_error, authentication_failure_reason(error, state.socket_mode)}
    )

    {:noreply, state}
  end

  def handle_info({:stop_after_authentication_error, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info({:node_pty, invoke_id, type, payload}, state) do
    case state.shells[invoke_id] do
      nil ->
        {:noreply, state}

      shell ->
        frame = Map.put(payload, "type", type)

        request(
          state,
          "node.shell.event",
          %{"invokeId" => invoke_id, "payload" => frame},
          {:shell_event, invoke_id, type}
        )

        if type == "exit" do
          request(
            state,
            "node.invoke.result",
            %{"invokeId" => invoke_id, "result" => %{"code" => payload["code"]}},
            {:invoke_result, invoke_id}
          )

          {:noreply, %{state | shells: Map.delete(state.shells, invoke_id)}}
        else
          _ = shell
          {:noreply, state}
        end
    end
  end

  def handle_info({:process_service_result, invoke_id, pid, result}, state) do
    case state.process_tasks[invoke_id] do
      %{pid: ^pid, monitor_ref: ref} ->
        Process.demonitor(ref, [:flush])
        state = %{state | process_tasks: Map.delete(state.process_tasks, invoke_id)}
        {:noreply, send_host_io_result(state, invoke_id, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:engine_delta, run_ref, text}, state) when is_binary(text) do
    case Map.get(state.run_refs, run_ref) do
      nil ->
        {:noreply, state}

      invoke_id ->
        invocation = Map.fetch!(state.invocations, invoke_id)
        next_bytes = invocation.delta_bytes + byte_size(text)
        next_count = invocation.delta_count + 1

        if next_bytes > result_content_limit(state) or
             next_count > LemonCore.JSONPayload.default_max_items() do
          _ = cancel_invocation_execution(state, invocation)

          state =
            state
            |> send_invoke_error(invoke_id, :result_payload_limit_exceeded)
            |> remove_invocation(invoke_id)

          {:noreply, state}
        else
          invocations =
            Map.update!(state.invocations, invoke_id, fn current ->
              %{
                current
                | deltas: [text | current.deltas],
                  delta_bytes: next_bytes,
                  delta_count: next_count
              }
            end)

          state = %{state | invocations: invocations}
          {:noreply, forward_event(state, invoke_id, RemoteEventCodec.encode_delta(text))}
        end
    end
  end

  def handle_info({:engine_event, run_ref, %{__event__: :completed} = completed}, state) do
    case Map.get(state.run_refs, run_ref) do
      nil ->
        {:noreply, state}

      invoke_id ->
        invocation = Map.fetch!(state.invocations, invoke_id)
        if invocation.monitor_ref, do: Process.demonitor(invocation.monitor_ref, [:flush])
        invocation = %{invocation | completed: completed, monitor_ref: nil}
        state = put_invocation(state, invoke_id, invocation)
        {:noreply, drain_events(state, invoke_id)}
    end
  end

  def handle_info({:engine_event, run_ref, event}, state) do
    case Map.get(state.run_refs, run_ref) do
      nil ->
        {:noreply, state}

      invoke_id ->
        {:noreply, forward_event(state, invoke_id, RemoteEventCodec.encode_engine(event))}
    end
  end

  def handle_info(
        %LemonCore.Event{
          type: :approval_requested,
          payload: %{pending: %{session_id: session_id}} = payload
        },
        state
      )
      when is_binary(session_id) do
    pending = payload.pending

    case invocation_for_run(state, pending.run_id) do
      nil ->
        {:noreply, state}

      {invoke_id, %{session_key: session_key} = invocation}
      when session_key == pending.session_key ->
        invocation = %{invocation | approvals: MapSet.put(invocation.approvals, pending.id)}
        state = put_invocation(state, invoke_id, invocation)
        {:noreply, forward_event(state, invoke_id, RemoteEventCodec.encode_approval(pending))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(%LemonCore.Event{type: type, payload: payload, meta: meta}, state)
      when type in [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted] and
             is_map(meta) and not is_map_key(meta, :remote_node) do
    case invocation_for_run(state, meta[:run_id]) do
      nil ->
        {:noreply, state}

      {invoke_id, _invocation} ->
        {:noreply,
         forward_event(state, invoke_id, RemoteEventCodec.encode_checkpoint(type, payload))}
    end
  end

  def handle_info({monitor_ref, result}, state) when is_reference(monitor_ref) do
    case Enum.find(state.invocations, fn {_id, invocation} ->
           Map.get(invocation, :service_task) != nil and invocation.monitor_ref == monitor_ref
         end) do
      {invoke_id, _invocation} ->
        {:noreply, complete_service_task(state, invoke_id, result)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Enum.find(state.process_tasks, fn {_, task} -> task.monitor_ref == monitor_ref end) do
      {invoke_id, _} ->
        _ = CodingAgent.ExecutionNode.ProcessService.cancel_invocation(self(), invoke_id)
        state = %{state | process_tasks: Map.delete(state.process_tasks, invoke_id)}
        {:noreply, send_invoke_error(state, invoke_id, :process_outcome_unknown)}

      nil ->
        case Enum.find(state.invocations, fn {_id, invocation} ->
               invocation.monitor_ref == monitor_ref
             end) do
          {invoke_id, invocation} ->
            reason =
              if Map.get(invocation, :service_task),
                do: invocation.failure_reason,
                else: {:runner_down, reason}

            state = send_invoke_error(state, invoke_id, reason)
            {:noreply, remove_invocation(state, invoke_id)}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:EXIT, socket, reason}, %{socket: socket} = state) do
    {:stop, {:socket_exited, reason}, state}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.shells, fn {_, shell} -> shell.pid == pid end) do
      {invoke_id, _} ->
        state = send_invoke_error(state, invoke_id, :pty_closed)
        {:noreply, %{state | shells: Map.delete(state.shells, invoke_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_all_invocations(state)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :private_execution_node)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
  end

  defp handle_socket_response(
         :pair_request,
         {:ok, %{"challengeToken" => _} = payload},
         %{invite_code: code} = state
       )
       when is_binary(code) do
    handle_socket_response(:pair_approve, {:ok, payload}, state)
  end

  defp handle_socket_response({:shell_event, invoke_id, _type}, result, state) do
    if shell = state.shells[invoke_id] do
      case result do
        {:ok, _} -> CodingAgent.ExecutionNode.PTY.ack(shell.pid)
        _ -> GenServer.stop(shell.pid, :normal)
      end
    end

    {:noreply, state}
  end

  defp handle_socket_response(:pair_request, {:ok, payload}, state) when is_map(payload) do
    case payload["pairingId"] do
      pairing_id when is_binary(pairing_id) and pairing_id != "" ->
        request(state, "node.pair.approve", %{"pairingId" => pairing_id}, :pair_approve)
        {:noreply, %{state | pairing_id: pairing_id, pairing_stage: :approving}}

      _ ->
        {:stop, {:pairing_failed, :missing_pairing_id}, state}
    end
  end

  defp handle_socket_response(:pair_approve, {:ok, payload}, state) when is_map(payload) do
    case payload["challengeToken"] do
      challenge when is_binary(challenge) and challenge != "" ->
        tag = {:pair_challenge, payload["nodeId"]}
        request(state, "connect.challenge", %{"challenge" => challenge}, tag)

        recovery_token = payload["token"] || state.recovery_token
        {:noreply, %{state | pairing_stage: :challenging, recovery_token: recovery_token}}

      _ ->
        {:stop, {:pairing_failed, :missing_challenge_token}, state}
    end
  end

  defp handle_socket_response({:pair_challenge, approved_node_id}, {:ok, payload}, state)
       when is_map(payload) do
    token = payload["token"]
    node_id = get_in(payload, ["identity", "nodeId"]) || approved_node_id

    with true <- is_binary(token) and token != "",
         true <- is_binary(node_id) and node_id != "",
         :ok <-
           state.token_store_module.save(
             state.name,
             %{
               "token" => token,
               "nodeId" => node_id,
               "controller" => state.controller,
               "recoveryToken" => state.recovery_token
             },
             state.token_store_opts
           ) do
      old_socket = state.socket
      :ok = state.socket_module.stop(old_socket)

      case connect_authenticated(
             %{state | socket: nil, pairing_stage: nil, invite_code: nil},
             token,
             node_id
           ) do
        {:ok, new_state} ->
          notify(new_state, {:status, :paired, node_id})
          {:noreply, new_state}

        {:error, reason} ->
          {:stop, reason, state}
      end
    else
      false -> {:stop, {:pairing_failed, :missing_session_token}, state}
      {:error, reason} -> {:stop, {:token_store_failed, reason}, state}
    end
  end

  defp handle_socket_response({:invoke_result, _invoke_id}, _result, state),
    do: {:noreply, state}

  defp handle_socket_response({:invoke_control_result, _control_id}, _result, state),
    do: {:noreply, state}

  defp handle_socket_response(tag, {:error, reason}, state)
       when tag in [:pair_request, :pair_approve] do
    handle_pairing_error(reason, state)
  end

  defp handle_socket_response({:pair_challenge, _node_id}, {:error, reason}, state) do
    handle_pairing_error(reason, state)
  end

  defp handle_socket_response({:invoke_event, invoke_id, seq}, result, state) do
    case Map.get(state.invocations, invoke_id) do
      %{inflight: ^seq} = invocation ->
        case result do
          {:ok, %{"received" => true, "seq" => ^seq}} ->
            state = put_invocation(state, invoke_id, %{invocation | inflight: nil})
            {:noreply, drain_events(state, invoke_id)}

          _ ->
            {:noreply, fail_stream(state, invoke_id, :event_delivery_failed)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_socket_response(_tag, _result, state), do: {:noreply, state}

  defp handle_pairing_error(reason, %{invite_code: code} = state)
       when is_binary(code) and reason in [:disconnected, :timeout] do
    {:stop, {:pairing_failed, :outcome_unknown}, state}
  end

  defp handle_pairing_error(reason, state) when reason in [:disconnected, :timeout] do
    state = if reason == :timeout, do: resume_pairing(state), else: state
    {:noreply, state}
  end

  defp handle_pairing_error(reason, state),
    do: {:stop, {:pairing_failed, safe_reason(reason)}, state}

  defp resume_pairing(%{pairing_id: pairing_id} = state)
       when is_binary(pairing_id) and pairing_id != "" do
    request(state, "node.pair.approve", %{"pairingId" => pairing_id}, :pair_approve)
    %{state | pairing_stage: :approving}
  end

  defp resume_pairing(state) do
    params =
      %{
        "nodeType" => "coding_agent",
        "nodeName" => state.name,
        "capabilities" => capabilities()
      }
      |> then(fn params ->
        if is_binary(state.invite_code),
          do: Map.put(params, "inviteCode", state.invite_code),
          else: maybe_put_recovery(params, state)
      end)

    request(state, "node.pair.request", params, :pair_request)
    %{state | pairing_stage: :requesting}
  end

  defp handle_node_event("node.invoke.request", payload, state) do
    if targeted?(payload, state) do
      invoke_id = payload["invokeId"]
      method = payload["method"]
      args = payload["args"]

      cond do
        not is_binary(invoke_id) or invoke_id == "" ->
          {:noreply, state}

        Map.has_key?(state.invocations, invoke_id) or Map.has_key?(state.shells, invoke_id) or
            Map.has_key?(state.process_tasks, invoke_id) ->
          {:noreply, state}

        not is_map(args) ->
          {:noreply, send_invoke_error(state, invoke_id, :invalid_arguments)}

        payload_error = validate_invocation_payload(method, args, state) ->
          {:noreply, send_invoke_error(state, invoke_id, payload_error)}

        method in CodingAgent.ExecutionNode.MemoryTransfer.methods() ->
          {:noreply, invoke_memory_transfer(state, invoke_id, method, args)}

        method in ["memory.list", "memory.search", "memory.get", "memory.add", "memory.delete"] ->
          {:noreply, invoke_memory(state, invoke_id, method, args)}

        method == "node.mcp.discover" ->
          {:noreply, start_discovery(state, invoke_id, args)}

        method == "node.profile.sync" ->
          sync_module = state.profile_sync_module
          cwd = state.default_cwd

          {:noreply,
           start_service_task(state, invoke_id, :profile_sync_failed, fn ->
             sync_module.apply(args, cwd)
           end)}

        method == "node.profile.sync.status" ->
          sync_module = state.profile_sync_module
          cwd = state.default_cwd

          {:noreply,
           start_service_task(state, invoke_id, :profile_sync_failed, fn ->
             sync_module.status(args, cwd)
           end)}

        method == "node.profile.paths" ->
          {:noreply,
           start_service_task(state, invoke_id, :profile_paths_failed, fn ->
             CodingAgent.ExecutionNode.ProfilePaths.get(args)
           end)}

        method == "coding_agent.run" ->
          {:noreply, start_invocation(state, invoke_id, args)}

        method in @process_methods and
            (not is_binary(state.node_id) or payload["nodeId"] != state.node_id) ->
          {:noreply, send_invoke_error(state, invoke_id, :node_mismatch)}

        method in @process_methods ->
          {:noreply,
           start_process_task(state, invoke_id, method, args, payload["nodeGeneration"])}

        method in @provider_methods and
            (not is_binary(state.node_id) or payload["nodeId"] != state.node_id) ->
          {:noreply, send_invoke_error(state, invoke_id, :node_mismatch)}

        method in @provider_methods and
            (not is_integer(payload["nodeGeneration"]) or payload["nodeGeneration"] < 0) ->
          {:noreply, send_invoke_error(state, invoke_id, :invalid_node_generation)}

        method in @provider_methods ->
          node_id = state.node_id
          cwd = state.default_cwd
          operation = String.replace_prefix(method, "node.providers.management.", "")
          authority = {self(), payload["nodeGeneration"]}

          {:noreply,
           start_service_task(state, invoke_id, :provider_management_failed, fn ->
             LemonCore.ProviderManagement.execute(operation, args,
               node_id: node_id,
               cwd: cwd,
               authority: authority
             )
           end)}

        method == "node.runtime.features" ->
          {:noreply, send_host_io_result(state, invoke_id, {:ok, runtime_features()})}

        method == "node.capabilities.get" ->
          result = CodingAgent.ExecutionNode.Capabilities.get(host_io_opts(state))
          {:noreply, send_host_io_result(state, invoke_id, result)}

        method in @host_io_methods ->
          result = CodingAgent.ExecutionNode.HostIO.handle(method, args, host_io_opts(state))
          {:noreply, send_host_io_result(state, invoke_id, result)}

        method in @shell_methods ->
          {:noreply, dispatch_shell(state, invoke_id, method, args)}

        true ->
          {:noreply, send_invoke_error(state, invoke_id, :unsupported_method)}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_node_event("node.invoke.cancel", payload, state) do
    invoke_id = payload["invokeId"]

    if targeted?(payload, state) do
      state =
        if is_binary(state.node_id) and payload["nodeId"] == state.node_id,
          do: cancel_process_task(state, invoke_id, payload["nodeGeneration"]),
          else: state

      case state.shells[invoke_id] do
        %{pid: pid} ->
          GenServer.stop(pid, :normal)
          {:noreply, %{state | shells: Map.delete(state.shells, invoke_id)}}

        nil ->
          case Map.get(state.invocations, invoke_id) do
            nil ->
              {:noreply, state}

            invocation ->
              _ = cancel_invocation_execution(state, invocation)
              {:noreply, remove_invocation(state, invoke_id)}
          end
      end
    else
      {:noreply, state}
    end
  end

  defp handle_node_event("node.invoke.control", payload, state) do
    if targeted?(payload, state) do
      {:noreply, apply_invocation_control(state, payload)}
    else
      {:noreply, state}
    end
  end

  defp handle_node_event("node.invoke.approval", payload, state) do
    invoke_id = payload["invokeId"]
    approval_id = payload["approvalId"]
    decision = Map.get(@approval_decisions, payload["decision"])

    case Map.get(state.invocations, invoke_id) do
      %{run_id: run_id, session_key: session_key, approvals: approvals} = invocation ->
        if targeted?(payload, state) and payload["runId"] == run_id and
             MapSet.member?(approvals, approval_id) and not is_nil(decision) do
          case ExecApprovals.resolve(approval_id, decision,
                 expected_run_id: run_id,
                 expected_session_key: session_key
               ) do
            {:ok, %{run_id: ^run_id, session_key: ^session_key, decision: ^decision}} ->
              invocation = %{invocation | approvals: MapSet.delete(approvals, approval_id)}
              {:noreply, put_invocation(state, invoke_id, invocation)}

            {:error, _} ->
              # Keep it owned so invocation teardown still cancels its waiter.
              {:noreply, state}
          end
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_node_event(_event, _payload, state), do: {:noreply, state}

  defp validate_invocation_payload("coding_agent.run", args, _state) do
    case LemonCore.JSONPayload.validate(args, LemonCore.ToolPolicy.execution_json_opts()) do
      {:ok, _} -> nil
      {:error, reason} -> reason
    end
  end

  defp validate_invocation_payload(_method, args, state), do: validate_payload(args, state)

  defp invoke_memory_transfer(state, invoke_id, method, args) do
    result = CodingAgent.ExecutionNode.MemoryTransfer.execute(method, args, state.node_id)

    if method in ["memory.transfer.prepare", "memory.transfer.snapshot"],
      do: send_memory_result(state, invoke_id, result, :snapshot_too_large),
      else: send_memory_result(state, invoke_id, result)
  end

  defp invoke_memory(state, invoke_id, "memory." <> operation, args) do
    result = LemonSkills.ProfileMemory.execute(operation, args["profileId"], args)
    send_memory_result(state, invoke_id, result)
  rescue
    _ -> send_invoke_error(state, invoke_id, :memory_unavailable)
  catch
    _, _ -> send_invoke_error(state, invoke_id, :memory_unavailable)
  end

  defp send_memory_result(state, invoke_id, result, overflow \\ :result_payload_limit_exceeded) do
    result =
      case result do
        {:ok, payload} -> %{"ok" => true, "payload" => payload}
        {:error, reason} -> %{"ok" => false, "error" => Atom.to_string(reason)}
      end

    params = %{"invokeId" => invoke_id, "result" => result}

    case LemonCore.JSONPayload.validate(params, max_bytes: result_content_limit(state)) do
      {:ok, _stats} ->
        request(state, "node.invoke.result", params, {:invoke_result, invoke_id})
        state

      {:error, _reason} when overflow == :snapshot_too_large ->
        send_memory_result(state, invoke_id, {:error, :snapshot_too_large})

      {:error, _reason} ->
        send_invoke_error(state, invoke_id, :result_payload_limit_exceeded)
    end
  end

  defp host_io_opts(state),
    do: [
      default_cwd: state.default_cwd,
      allowed_roots: state.allowed_roots,
      node_id: state.node_id
    ]

  defp start_process_task(state, invoke_id, method, args, generation) do
    cond do
      not is_integer(generation) or generation < 0 ->
        send_invoke_error(state, invoke_id, :invalid_node_generation)

      Map.has_key?(args, "nodeId") and args["nodeId"] != state.node_id ->
        send_invoke_error(state, invoke_id, :node_mismatch)

      map_size(state.process_tasks) >= 64 ->
        send_invoke_error(state, invoke_id, :process_busy)

      true ->
        owner = self()

        opts =
          host_io_opts(state) ++
            [session_generation: generation, invoke_id: invoke_id, owner: owner]

        args = Map.put(args, "nodeId", state.node_id)

        {pid, ref} =
          spawn_monitor(fn ->
            result = CodingAgent.ExecutionNode.ProcessService.handle(method, args, opts)
            send(owner, {:process_service_result, invoke_id, self(), result})
          end)

        task = %{
          pid: pid,
          monitor_ref: ref,
          generation: generation,
          method: method,
          process_id: args["processId"],
          node_id: state.node_id
        }

        %{state | process_tasks: Map.put(state.process_tasks, invoke_id, task)}
    end
  end

  defp cancel_process_task(state, invoke_id, generation) do
    case state.process_tasks[invoke_id] do
      nil ->
        state

      %{generation: ^generation} = task when is_integer(generation) and generation >= 0 ->
        _ = cancel_process_receipt(task, invoke_id)
        _ = CodingAgent.ExecutionNode.ProcessService.cancel_invocation(self(), invoke_id)
        Process.exit(task.pid, :kill)
        Process.demonitor(task.monitor_ref, [:flush])
        %{state | process_tasks: Map.delete(state.process_tasks, invoke_id)}

      _ ->
        state
    end
  end

  defp cancel_process_receipt(%{method: "node.process.run"} = task, invoke_id) do
    CodingAgent.ExecutionNode.ProcessService.handle(
      "node.process.cancel",
      %{"nodeId" => task.node_id, "processId" => task.process_id},
      node_id: task.node_id,
      session_generation: task.generation,
      invoke_id: invoke_id,
      owner: self()
    )
  end

  defp cancel_process_receipt(_, _), do: :ok

  defp send_host_io_result(state, invoke_id, {:ok, result}) do
    request(
      state,
      "node.invoke.result",
      %{"invokeId" => invoke_id, "result" => result},
      {:invoke_result, invoke_id}
    )

    state
  end

  defp send_host_io_result(state, invoke_id, {:error, reason}),
    do: send_invoke_error(state, invoke_id, reason)

  defp dispatch_shell(state, invoke_id, "node.shell.open", args) do
    if map_size(state.shells) < 64 and is_binary(args["shellId"]) do
      case CodingAgent.ExecutionNode.PTY.start_link(self(), invoke_id, args, host_io_opts(state)) do
        {:ok, pid} ->
          %{state | shells: Map.put(state.shells, invoke_id, %{pid: pid, id: args["shellId"]})}

        {:error, _} ->
          send_invoke_error(state, invoke_id, :pty_unavailable)
      end
    else
      send_invoke_error(state, invoke_id, :shell_limit)
    end
  end

  defp dispatch_shell(state, invoke_id, method, args) do
    shell_id = args["shellId"]

    result =
      case state.shells[args["openInvokeId"]] do
        %{pid: pid, id: ^shell_id} ->
          try do
            operation = String.replace_prefix(method, "node.shell.", "")

            case CodingAgent.ExecutionNode.PTY.command(pid, operation, args) do
              :ok -> {:ok, %{"shellId" => shell_id, "accepted" => true}}
              error -> error
            end
          catch
            :exit, _ -> {:error, :shell_closed}
          end

        _ ->
          {:error, :shell_not_found}
      end

    send_host_io_result(state, invoke_id, result)
  end

  defp start_discovery(state, invoke_id, %{"server" => server}) when is_map(server) do
    discovery_module = state.mcp_discovery_module
    cwd = state.default_cwd

    start_service_task(state, invoke_id, :discovery_failed, fn ->
      discovery_module.discover(server, cwd)
    end)
  end

  defp start_discovery(state, invoke_id, _args),
    do: send_invoke_error(state, invoke_id, :invalid_config)

  defp start_service_task(state, invoke_id, failure_reason, run) do
    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        try do
          run.()
        rescue
          _ -> {:error, failure_reason}
        catch
          _, _ -> {:error, failure_reason}
        end
      end)

    invocation = %{
      service_task: task,
      monitor_ref: task.ref,
      failure_reason: failure_reason,
      run_ref: nil
    }

    %{state | invocations: Map.put(state.invocations, invoke_id, invocation)}
  rescue
    _ -> send_invoke_error(state, invoke_id, :runtime_unavailable)
  catch
    _, _ -> send_invoke_error(state, invoke_id, :runtime_unavailable)
  end

  defp complete_service_task(state, invoke_id, {:ok, result}) when is_map(result) do
    params = %{"invokeId" => invoke_id, "result" => result}

    state =
      case LemonCore.JSONPayload.validate(
             params,
             LemonCore.ToolPolicy.execution_json_opts(max_bytes: result_content_limit(state))
           ) do
        {:ok, _stats} ->
          request(state, "node.invoke.result", params, {:invoke_result, invoke_id})
          state

        {:error, _} ->
          send_invoke_error(state, invoke_id, :result_payload_limit_exceeded)
      end

    remove_invocation(state, invoke_id)
  end

  defp complete_service_task(state, invoke_id, {:error, reason})
       when reason in [
              :target_mismatch,
              :invalid_request,
              :forbidden,
              :provider_binding_rejected,
              :invalid_provider,
              :unsupported_method,
              :invalid_api_key,
              :invalid_model,
              :invalid_target,
              :invalid_config,
              :invalid_cwd,
              :runtime_unavailable,
              :mcp_disabled,
              :secret_resolution_failed,
              :connection_failed,
              :discovery_failed,
              :owner_unavailable,
              :invalid_profile_snapshot,
              :revision_mismatch,
              :mutation_conflict,
              :unsafe_profile_boundary,
              :profile_sync_failed,
              :profile_sync_corrupt,
              :invalid_url,
              :invalid_origin_policy,
              :origin_not_allowed,
              :dns_resolution_failed,
              :invalid_dns_answer,
              :too_many_dns_addresses,
              :destination_not_public,
              :destination_not_allowed
            ] do
    state |> send_invoke_error(invoke_id, reason) |> remove_invocation(invoke_id)
  end

  defp complete_service_task(state, invoke_id, _result) do
    failure_reason = Map.fetch!(state.invocations, invoke_id).failure_reason
    state |> send_invoke_error(invoke_id, failure_reason) |> remove_invocation(invoke_id)
  end

  defp start_invocation(state, invoke_id, args) do
    with {:ok, request, run_opts} <- execution_request(args, state, invoke_id),
         true <- is_nil(invocation_for_run(state, request.run_id)),
         {:ok, run_ref, context} <- start_local_run(state, request, run_opts) do
      runner_pid = Map.get(context, :runner_pid)
      monitor_ref = if is_pid(runner_pid), do: Process.monitor(runner_pid)

      invocation = %{
        run_ref: run_ref,
        context: context,
        monitor_ref: monitor_ref,
        deltas: [],
        delta_bytes: 0,
        delta_count: 0,
        run_id: request.run_id,
        session_key: request.session_key,
        event_seq: 0,
        event_queue: :queue.new(),
        pending_events: 0,
        inflight: nil,
        completed: nil,
        approvals: MapSet.new(),
        memory_snapshot: memory_snapshot(request)
      }

      %{
        state
        | invocations: Map.put(state.invocations, invoke_id, invocation),
          run_refs: Map.put(state.run_refs, run_ref, invoke_id)
      }
    else
      {:error, reason} -> send_invoke_error(state, invoke_id, reason)
      false -> send_invoke_error(state, invoke_id, :run_already_active)
    end
  end

  defp start_local_run(state, request, run_opts) do
    socket = state.socket
    socket_module = state.socket_module

    run_opts =
      run_opts
      |> Map.put(:native_followup_submit, fn source, request ->
        params = %{
          "sourceRunId" => source.run_id,
          "lineageHandle" => source.lineage_handle,
          "request" => %{
            "runId" => request.run_id,
            "agentId" => request.agent_id,
            "sessionKey" => request.session_key,
            "prompt" => request.prompt,
            "images" => request.images || [],
            "model" => request.model,
            "modelExplicit" => request.model_explicit,
            "cwd" => request.cwd,
            "toolPolicy" => request.tool_policy,
            "meta" => LemonCore.RunStore.execution_projection(request.meta || %{})
          }
        }

        case native_controller_request(socket_module, socket, "node.native.followup", params) do
          {:ok, %{"runId" => id}} when is_binary(id) and id != "" -> {:ok, id}
          {:error, :outcome_unknown} -> {:error, :outcome_unknown}
          _ -> {:error, :native_followup_unavailable}
        end
      end)
      |> Map.put(:native_source_floor_fun, fn source, policy ->
        params = %{"sourceRunId" => source.run_id, "toolPolicy" => policy}

        params =
          if Map.has_key?(source, :lineage_handle),
            do: Map.put(params, "lineageHandle", source.lineage_handle),
            else: params

        case native_controller_request(socket_module, socket, "node.native.lineage.floor", params) do
          {:ok, _} -> :ok
          _ -> {:error, :native_source_floor_unavailable}
        end
      end)

    topic = Bus.run_topic(request.run_id)
    :ok = Bus.subscribe(topic)

    case state.executor_module.start_run(
           request,
           Map.put(run_opts, :approval_timeout_ms, 600_000),
           self()
         ) do
      {:ok, _run_ref, _context} = result ->
        result

      {:error, _reason} = error ->
        Bus.unsubscribe(topic)
        error
    end
  end

  defp native_controller_request(socket_module, socket, method, params) do
    case LemonCore.JSONPayload.round_trip(params, LemonCore.ToolPolicy.execution_json_opts()) do
      {:ok, params} ->
        ref = make_ref()
        socket_module.request(socket, method, params, {:native_reply, self(), ref}, 30_000)

        receive do
          {:native_controller_reply, ^ref, {:ok, payload}} ->
            {:ok, payload}

          {:native_controller_reply, ^ref, {:error, reason}}
          when reason in [:timeout, :disconnected] ->
            {:error, :outcome_unknown}

          {:native_controller_reply, ^ref, {:error, _}} ->
            {:error, :native_admission_unavailable}
        after
          31_000 -> {:error, :outcome_unknown}
        end

      _ ->
        {:error, :invalid_native_request}
    end
  catch
    _, _ -> {:error, :native_admission_unavailable}
  end

  @doc false
  @spec execution_request(map(), struct(), String.t()) ::
          {:ok, ExecutionRequest.t(), map()} | {:error, term()}
  def execution_request(args, state, invoke_id) when is_map(args) do
    version = value(args, "version")
    prompt = value(args, "prompt")
    requested_cwd = value(args, "cwd")
    run_id = optional_string(value(args, "runId")) || "node:#{invoke_id}"
    session_key = optional_string(value(args, "sessionKey")) || "node:#{state.name}:#{run_id}"

    with :ok <- validate_version(version),
         {:ok, images} <-
           LemonAi.ImageInputs.validate(Map.get(args, "images", Map.get(args, :images, []))),
         {:ok, prompt} <- invocation_prompt(prompt, images),
         {:ok, cwd} <- invocation_cwd(requested_cwd, state.default_cwd),
         {:ok, meta} <-
           args |> value("meta") |> normalize_meta() |> normalize_invocation_proof(run_id),
         {:ok, execution_context} <- ExecutionContext.decode(value(args, "executionContext")),
         :ok <- validate_context_run_id(execution_context, run_id),
         {:ok, execution_context} <-
           ExecutionContext.restrict_capabilities(execution_context, state.execution_capabilities),
         {:ok, execution_context} <- ExecutionContext.bind_workspace(execution_context, cwd),
         {:ok, requested_policy} <-
           ToolPolicy.resolve(value(args, "toolPolicy"), execution_context.tool_policy),
         {:ok, policy} <- ToolPolicy.restrict(execution_context.tool_policy, requested_policy),
         {:ok, execution_context} <-
           ExecutionContext.validate(%{execution_context | tool_policy: policy}) do
      request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        images: images,
        cwd: cwd,
        resume: normalize_resume(value(args, "resume")),
        lane: value(args, "lane"),
        tool_policy: ToolPolicy.to_map(policy),
        execution_context: execution_context,
        meta: meta
      }

      {:ok, request, %{cwd: cwd, run_id: run_id}}
    end
  end

  defp complete_invocation(state, invoke_id, completed) do
    invocation = Map.fetch!(state.invocations, invoke_id)
    accumulated = invocation.deltas |> Enum.reverse() |> IO.iodata_to_binary()

    answer =
      case completed.answer do
        answer when is_binary(answer) and answer != "" -> answer
        _ -> accumulated
      end

    record_memory_completion(state, invocation, answer, completed)

    result = %{
      "completed" => %{
        "ok" => completed.ok == true,
        "answer" => answer,
        "error" => Codec.json_safe(completed.error),
        "usage" => Codec.json_safe(completed.usage),
        "meta" => normalize_completed_meta(completed.meta),
        "resume" => Codec.json_safe(completed.resume)
      }
    }

    params = %{"invokeId" => invoke_id, "result" => result}

    case LemonCore.JSONPayload.validate(
           params,
           LemonCore.ToolPolicy.execution_json_opts(max_bytes: result_content_limit(state))
         ) do
      {:ok, _stats} ->
        request(state, "node.invoke.result", params, {:invoke_result, invoke_id})

      {:error, _reason} ->
        send_invoke_error(state, invoke_id, :result_payload_limit_exceeded)
    end

    remove_invocation(state, invoke_id)
  end

  # Only original admitted request ownership can stamp destination-local memory.
  # Provider/completion metadata and MCP configuration are never part of this snapshot.
  defp memory_snapshot(%ExecutionRequest{} = request) do
    meta =
      Map.take(
        request.meta || %{},
        [:profile_id, :invocation_context_key, :memory_context_key, :memory_context_verified]
      )

    agent =
      case Map.fetch(request.meta || %{}, :agent_id) do
        {:ok, canonical} -> canonical
        :error -> LemonCore.SessionKey.agent_id(request.session_key)
      end

    with {:ok, {:private, _key}} <- ContextScope.scope(meta),
         true <- is_binary(agent) and byte_size(agent) in 1..64 and String.valid?(agent),
         {:ok, meta} <- memory_home(meta) do
      %{
        run_id: request.run_id,
        session_key: request.session_key,
        agent_id: agent,
        cwd: request.cwd,
        workspace_key: request.cwd,
        prompt: Document.summary_text(request.prompt),
        meta: meta,
        started_at: System.system_time(:millisecond)
      }
    else
      _ -> nil
    end
  end

  defp memory_home(meta) do
    # Bind this destination's canonical home at admission, not later from mutable
    # completion metadata or an application path change while ingest is queued.
    meta = Project.history_metadata(meta)
    if is_binary(meta["home_digest"]), do: {:ok, meta}, else: {:error, :invalid_memory_home}
  end

  defp record_memory_completion(_state, %{memory_snapshot: nil}, _answer, _completed), do: :ok

  defp record_memory_completion(state, %{memory_snapshot: snapshot}, answer, completed) do
    outcome =
      LemonCore.RunOutcome.infer(%{
        completed: %{ok: completed.ok == true, answer: answer, error: completed.error}
      })

    summary =
      snapshot
      |> Map.drop([:run_id, :started_at])
      |> Map.put(:outcome, outcome)
      |> Map.put(:completed, %{ok: completed.ok == true, answer: Document.summary_text(answer)})

    Ingest.ingest(
      state.memory_ingest_server,
      snapshot.run_id,
      %{events: [], started_at: snapshot.started_at},
      summary
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp send_invoke_error(state, invoke_id, reason) do
    request(
      state,
      "node.invoke.result",
      %{"invokeId" => invoke_id, "error" => Codec.json_safe(reason)},
      {:invoke_result, invoke_id}
    )

    state
  end

  defp apply_invocation_control(state, payload) do
    control_id = payload["controlId"]
    invoke_id = payload["invokeId"]
    run_id = payload["runId"]
    operation = control_operation(payload["operation"])
    text = payload["text"]

    if valid_control_identity?(control_id, invoke_id, run_id) do
      result =
        case Map.get(state.invocations, invoke_id) do
          nil ->
            {:error, "terminal"}

          %{service_task: _task} ->
            {:error, "unsupported"}

          %{run_id: invocation_run_id} when invocation_run_id != run_id ->
            {:error, "run_mismatch"}

          invocation ->
            execute_invocation_control(state, invocation, operation, text)
        end

      send_control_result(state, control_id, invoke_id, run_id, result)
    else
      state
    end
  end

  defp execute_invocation_control(_state, _invocation, :invalid, _text),
    do: {:error, "unsupported_operation"}

  defp execute_invocation_control(_state, _invocation, _operation, text)
       when not is_binary(text),
       do: {:error, "invalid_text"}

  defp execute_invocation_control(_state, _invocation, _operation, ""),
    do: {:error, "invalid_text"}

  defp execute_invocation_control(_state, _invocation, _operation, text)
       when byte_size(text) > @max_control_text_bytes,
       do: {:error, "text_too_large"}

  defp execute_invocation_control(state, invocation, operation, text) do
    if String.valid?(text) do
      try do
        case apply(state.executor_module, operation, [invocation.context, text]) do
          :ok -> :ok
          {:error, :unsupported} -> {:error, "unsupported"}
          {:error, _reason} -> {:error, "rejected"}
          _other -> {:error, "rejected"}
        end
      rescue
        _error -> {:error, "executor_error"}
      catch
        :exit, _reason -> {:error, "executor_unavailable"}
        _kind, _reason -> {:error, "executor_error"}
      end
    else
      {:error, "invalid_text"}
    end
  end

  defp send_control_result(state, control_id, invoke_id, run_id, result) do
    params = %{
      "controlId" => control_id,
      "invokeId" => invoke_id,
      "runId" => run_id,
      "accepted" => result == :ok
    }

    params =
      case result do
        {:error, reason} -> Map.put(params, "reason", reason)
        :ok -> params
      end

    request(
      state,
      "node.invoke.control.result",
      params,
      {:invoke_control_result, control_id}
    )

    state
  end

  defp valid_control_identity?(control_id, invoke_id, run_id) do
    Enum.all?([control_id, invoke_id, run_id], &(is_binary(&1) and &1 != ""))
  end

  defp control_operation("steer"), do: :steer
  defp control_operation("redirect"), do: :redirect
  defp control_operation(_operation), do: :invalid

  defp validate_payload(args, state) do
    case LemonCore.JSONPayload.validate(
           args,
           LemonCore.ToolPolicy.execution_json_opts(max_bytes: payload_limit(state))
         ) do
      {:ok, _stats} -> nil
      {:error, reason} -> {:invalid_request_payload, payload_error_kind(reason)}
    end
  end

  defp payload_error_kind({kind, _detail})
       when kind in [:max_bytes, :max_depth, :max_items, :not_json_safe],
       do: kind

  defp payload_error_kind(_reason), do: :invalid

  defp update_payload_limit(state, hello) do
    advertised = get_in(hello, ["policy", "maxPayload"])

    if is_integer(advertised) and advertised > 0 do
      %{state | max_payload_bytes: advertised}
    else
      state
    end
  end

  defp payload_limit(%{max_payload_bytes: bytes}) when is_integer(bytes) and bytes > 0, do: bytes
  defp payload_limit(_state), do: LemonCore.JSONPayload.default_max_bytes()

  defp result_content_limit(state), do: max(payload_limit(state) - 8_192, 1)

  defp remove_invocation(state, invoke_id) do
    case Map.pop(state.invocations, invoke_id) do
      {nil, _invocations} ->
        state

      {invocation, invocations} ->
        if task = Map.get(invocation, :service_task) do
          if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
        else
          Bus.unsubscribe(Bus.run_topic(invocation.run_id))
          Enum.each(invocation.approvals, &ExecApprovals.cancel(&1, "remote invocation ended"))
        end

        if invocation.monitor_ref, do: Process.demonitor(invocation.monitor_ref, [:flush])

        %{
          state
          | invocations: invocations,
            run_refs: Map.delete(state.run_refs, invocation.run_ref)
        }
    end
  end

  defp request(state, method, params, tag) do
    state.socket_module.request(state.socket, method, params, tag, 30_000)
  end

  defp resolve_token(_state, token) when is_binary(token) and token != "",
    do: {:ok, token, nil}

  defp resolve_token(state, _token) do
    load_opts =
      state.token_store_opts
      |> Keyword.put(:controller, state.controller)
      |> maybe_put_requested_node_id(state.requested_node_id)

    case state.token_store_module.load(state.name, load_opts) do
      {:ok, record} ->
        stored_token(record, state.controller)

      {:error, :not_found} ->
        {:error, :missing_node_token}

      {:error, reason} ->
        {:error, {:token_load_failed, reason}}

      _ ->
        {:error, :missing_node_token}
    end
  end

  defp stored_token(record, controller) do
    token = record["token"]
    node_id = record["nodeId"]

    cond do
      record["controller"] != controller -> {:error, :stored_token_controller_mismatch}
      not is_binary(node_id) or node_id == "" -> {:error, :stored_token_missing_node_id}
      not is_binary(token) or token == "" -> {:error, :missing_node_token}
      true -> {:ok, token, node_id}
    end
  end

  defp prepare_pairing_identity(state) do
    load_opts =
      state.token_store_opts
      |> Keyword.put(:controller, state.controller)
      |> maybe_put_requested_node_id(state.requested_node_id)

    case state.token_store_module.load(state.name, load_opts) do
      {:ok, record} ->
        node_id = record["nodeId"]
        recovery_token = record["recoveryToken"]

        cond do
          not is_binary(node_id) or node_id == "" ->
            {:error, :stored_token_missing_node_id}

          is_binary(recovery_token) and recovery_token != "" ->
            {:ok, %{state | recovery_node_id: node_id, recovery_token: recovery_token}}

          state.repair ->
            {:ok, %{state | recovery_node_id: node_id}}

          true ->
            {:error, :missing_node_recovery_token}
        end

      {:error, :not_found} when is_binary(state.requested_node_id) and state.repair ->
        {:ok, %{state | recovery_node_id: state.requested_node_id}}

      {:error, :not_found} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:token_load_failed, reason}}

      _ ->
        {:ok, state}
    end
  end

  defp maybe_put_requested_node_id(opts, node_id) when is_binary(node_id) and node_id != "",
    do: Keyword.put(opts, :node_id, node_id)

  defp maybe_put_requested_node_id(opts, _node_id), do: opts

  defp maybe_put_recovery(params, %{recovery_node_id: node_id, recovery_token: token})
       when is_binary(node_id) and node_id != "" and is_binary(token) and token != "" do
    Map.merge(params, %{"nodeId" => node_id, "recoveryToken" => token})
  end

  defp maybe_put_recovery(params, %{recovery_node_id: node_id, repair: true})
       when is_binary(node_id) and node_id != "" do
    Map.merge(params, %{"nodeId" => node_id, "repair" => true})
  end

  defp maybe_put_recovery(params, _state), do: params

  defp targeted?(payload, state) do
    node_id = payload["nodeId"]
    node_name = payload["nodeName"]

    cond do
      is_binary(node_id) -> node_id == state.node_id
      is_binary(node_name) -> node_name == state.name
      true -> false
    end
  end

  defp validate_version(@execution_protocol_version), do: :ok
  defp validate_version(_), do: {:error, :unsupported_protocol_version}

  defp invocation_cwd(nil, default_cwd), do: existing_directory(default_cwd)
  defp invocation_cwd("", _default_cwd), do: {:error, :invalid_cwd}

  defp invocation_cwd(cwd, default_cwd) when is_binary(cwd) do
    cwd =
      case Path.type(cwd) do
        :absolute -> cwd
        _ -> Path.expand(cwd, default_cwd)
      end

    existing_directory(cwd)
  end

  defp invocation_cwd(_cwd, _default_cwd), do: {:error, :invalid_cwd}

  defp existing_directory(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, {:cwd_not_found, expanded}}
  end

  defp existing_directory(_cwd), do: {:error, :invalid_cwd}

  defp controller_url(url, allow_insecure?) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      uri.scheme == "wss" and is_binary(uri.host) and uri.host != "" ->
        {:ok, URI.to_string(uri)}

      uri.scheme == "ws" and loopback_host?(uri.host) ->
        {:ok, URI.to_string(uri)}

      uri.scheme == "ws" and is_binary(uri.host) and uri.host != "" and allow_insecure? == true ->
        {:ok, URI.to_string(uri)}

      uri.scheme == "ws" and is_binary(uri.host) and uri.host != "" ->
        {:error, :insecure_controller_url}

      true ->
        {:error, :invalid_controller_url}
    end
  end

  defp controller_url(_url, _allow_insecure?), do: {:error, :invalid_controller_url}

  defp loopback_host?(host) when is_binary(host) do
    normalized = String.downcase(host)

    normalized == "localhost" or String.ends_with?(normalized, ".localhost") or
      parsed_loopback?(normalized)
  end

  defp loopback_host?(_host), do: false

  defp parsed_loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  defp nonempty(value, reason) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp nonempty(_value, reason), do: {:error, reason}

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_), do: nil

  defp invocation_prompt(prompt, []) do
    nonempty(prompt, :missing_prompt)
  end

  defp invocation_prompt(nil, [_ | _]), do: {:ok, ""}

  defp invocation_prompt(prompt, [_ | _]) when is_binary(prompt),
    do: {:ok, String.trim(prompt)}

  defp invocation_prompt(_prompt, _images), do: {:error, :invalid_prompt}

  defp normalize_resume(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value),
       do: %{engine: engine, value: value}

  defp normalize_resume(_), do: nil

  defp normalize_meta(meta) when is_map(meta) do
    meta
    |> Map.delete("node")
    |> Map.delete(:node)
    |> atomize_known_keys([
      :model,
      :model_explicit,
      :thinking_level,
      :system_prompt,
      :agent_id,
      :profile_id,
      :invocation_context_key,
      :memory_context_key,
      :memory_context_verified,
      :shared_memory_grant,
      :resume_source,
      :acp_session_id,
      :acp_client_terminal,
      :acp_client_fs_read_text_file,
      :acp_client_fs_write_text_file,
      :async_followups,
      :invocation_context_key,
      :memory_context_key,
      :memory_context_verified,
      :shared_memory_grant,
      :invocation_proof,
      :invocation_proof_verified,
      :native_lineage_handle,
      :native_lineage_run_id,
      :profile_id,
      :profile_instructions,
      :mcp_servers
    ])
    |> normalize_thinking_level()
    |> normalize_resume_source()
  end

  defp normalize_meta(_), do: %{}

  defp normalize_invocation_proof(meta, run_id) do
    if Map.get(meta, :invocation_proof_verified) == true do
      fields = [
        run_id: "runId",
        server_name: "serverName",
        server_url: "serverUrl",
        header_name: "headerName",
        secret_name: "secretName"
      ]

      proof = Map.get(meta, :invocation_proof)

      descriptor =
        if is_map(proof) and map_size(proof) == 5 and
             Enum.all?(fields, fn {key, _} ->
               Map.has_key?(proof, key) != Map.has_key?(proof, Atom.to_string(key))
             end) do
          Map.new(fields, fn {key, wire} ->
            {wire, Map.get(proof, key, Map.get(proof, Atom.to_string(key)))}
          end)
        end

      with true <- Map.get(meta, :memory_context_verified) == true,
           key when is_binary(key) and key != "" <- Map.get(meta, :invocation_context_key),
           :ok <- LemonCore.RunRequest.validate_invocation_context_key(key),
           memory_key when is_binary(memory_key) and memory_key != "" <-
             Map.get(meta, :memory_context_key),
           :ok <- LemonCore.RunRequest.validate_invocation_context_key(memory_key),
           {:ok, record} <-
             LemonCore.InvocationProof.validate(descriptor, run_id, meta[:mcp_servers]) do
        {:ok,
         meta |> Map.put(:invocation_proof, record) |> Map.put(:invocation_proof_verified, true)}
      else
        _ -> {:error, :invalid_invocation_proof}
      end
    else
      {:ok, meta}
    end
  end

  defp normalize_thinking_level(meta) do
    allowed = %{
      "off" => :off,
      "minimal" => :minimal,
      "low" => :low,
      "medium" => :medium,
      "high" => :high,
      "xhigh" => :xhigh,
      "auto" => :auto
    }

    case meta[:thinking_level] do
      value when is_binary(value) -> Map.put(meta, :thinking_level, Map.get(allowed, value))
      _ -> meta
    end
  end

  defp normalize_resume_source(meta) do
    case meta[:resume_source] do
      "auto" -> Map.put(meta, :resume_source, :auto)
      "explicit" -> Map.put(meta, :resume_source, :explicit)
      _ -> meta
    end
  end

  defp validate_context_run_id(%ExecutionContext{run_id: run_id}, run_id), do: :ok

  defp validate_context_run_id(_context, _run_id),
    do: {:error, :execution_context_run_id_mismatch}

  defp atomize_known_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      string_key = Atom.to_string(key)

      cond do
        Map.has_key?(acc, key) ->
          Map.delete(acc, string_key)

        Map.has_key?(acc, string_key) ->
          {value, acc} = Map.pop(acc, string_key)
          Map.put(acc, key, value)

        true ->
          acc
      end
    end)
  end

  defp normalize_completed_meta(meta) when is_map(meta), do: Codec.json_safe(meta)
  defp normalize_completed_meta(_), do: nil

  defp maybe_put_auth(params, token) when is_binary(token) and token != "" do
    Map.put(params, "auth", %{"token" => token})
  end

  defp maybe_put_auth(params, _token), do: params

  defp authentication_failure_reason(error, :pairing) do
    message =
      case error do
        %{"message" => message} when is_binary(message) -> String.downcase(message)
        _ -> ""
      end

    cond do
      String.contains?(message, "operator authentication is required") ->
        :controller_operator_token_not_configured

      String.contains?(message, "operator token is required") ->
        :operator_token_required

      String.contains?(message, "operator token is invalid") ->
        :operator_token_invalid

      true ->
        :operator_authentication_failed
    end
  end

  defp authentication_failure_reason(_error, :node), do: :node_authentication_failed
  defp authentication_failure_reason(_error, _mode), do: :authentication_failed

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key_atom(key)) do
      {:ok, canonical} -> canonical
      :error -> Map.get(map, key)
    end
  end

  defp key_atom("version"), do: :version
  defp key_atom("runId"), do: :run_id
  defp key_atom("sessionKey"), do: :session_key
  defp key_atom("prompt"), do: :prompt
  defp key_atom("images"), do: :images
  defp key_atom("cwd"), do: :cwd
  defp key_atom("resume"), do: :resume
  defp key_atom("lane"), do: :lane
  defp key_atom("toolPolicy"), do: :tool_policy
  defp key_atom("executionContext"), do: :execution_context
  defp key_atom("meta"), do: :meta

  defp notify(%{notify_pid: pid}, message) when is_pid(pid) do
    send(pid, {:execution_node_worker, self(), message})
  end

  defp notify(_state, _message), do: :ok

  defp cancel_all_invocations(state) do
    _ = CodingAgent.ExecutionNode.ProcessService.cancel_owner(self())

    Enum.each(state.process_tasks, fn {invoke_id, task} ->
      _ = cancel_process_receipt(task, invoke_id)
      Process.exit(task.pid, :kill)
      Process.demonitor(task.monitor_ref, [:flush])
    end)

    Enum.reduce(state.invocations, state, fn {invoke_id, invocation}, current ->
      _ = cancel_invocation_execution(state, invocation)
      remove_invocation(current, invoke_id)
    end)
    |> then(fn current ->
      Enum.each(current.shells, fn {_, shell} ->
        if Process.alive?(shell.pid), do: GenServer.stop(shell.pid, :normal)
      end)

      %{current | shells: %{}, process_tasks: %{}}
    end)
  end

  defp invocation_for_run(state, run_id) when is_binary(run_id) do
    Enum.find(state.invocations, fn {_id, invocation} ->
      Map.get(invocation, :run_id) == run_id
    end)
  end

  defp invocation_for_run(_state, _run_id), do: nil

  defp put_invocation(state, invoke_id, invocation) do
    %{state | invocations: Map.put(state.invocations, invoke_id, invocation)}
  end

  defp forward_event(state, _invoke_id, :ignore), do: state

  defp forward_event(state, invoke_id, {:error, _reason}),
    do: fail_stream(state, invoke_id, :event_payload_limit_exceeded)

  defp forward_event(state, invoke_id, {:ok, event}) do
    invocation = Map.fetch!(state.invocations, invoke_id)

    if invocation.pending_events >= @max_pending_events do
      fail_stream(state, invoke_id, :event_backpressure_limit_exceeded)
    else
      invocation = %{
        invocation
        | event_queue: :queue.in(event, invocation.event_queue),
          pending_events: invocation.pending_events + 1
      }

      state |> put_invocation(invoke_id, invocation) |> drain_events(invoke_id)
    end
  end

  defp drain_events(state, invoke_id) do
    invocation = Map.fetch!(state.invocations, invoke_id)

    if is_nil(invocation.inflight) do
      case :queue.out(invocation.event_queue) do
        {{:value, event}, queue} ->
          seq = invocation.event_seq + 1
          params = %{"invokeId" => invoke_id, "seq" => seq, "event" => event}

          case LemonCore.JSONPayload.validate(params,
                 max_bytes: min(result_content_limit(state), 65_536)
               ) do
            {:ok, _stats} ->
              request(state, "node.invoke.event", params, {:invoke_event, invoke_id, seq})

              put_invocation(state, invoke_id, %{
                invocation
                | event_seq: seq,
                  inflight: seq,
                  event_queue: queue,
                  pending_events: invocation.pending_events - 1
              })

            {:error, _reason} ->
              fail_stream(state, invoke_id, :event_payload_limit_exceeded)
          end

        {:empty, _queue} ->
          if invocation.completed,
            do: complete_invocation(state, invoke_id, invocation.completed),
            else: state
      end
    else
      state
    end
  end

  defp fail_stream(state, invoke_id, reason) do
    invocation = Map.fetch!(state.invocations, invoke_id)
    _ = cancel_invocation_execution(state, invocation)
    state |> send_invoke_error(invoke_id, reason) |> remove_invocation(invoke_id)
  end

  defp cancel_invocation_execution(_state, %{service_task: task}) do
    if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    :ok
  end

  # Completed native runners have already stopped. Their remaining invocation
  # state owns only transport draining and approval cleanup, not live execution.
  defp cancel_invocation_execution(_state, %{completed: completed})
       when not is_nil(completed), do: :ok

  defp cancel_invocation_execution(state, invocation) do
    state.executor_module.cancel(invocation.context)
  catch
    # The runner may finish concurrently with cancellation even before its
    # completion/monitor message reaches this worker. Cleanup must still proceed.
    :exit, _reason -> :ok
  end

  defp safe_reason(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 500)
    |> String.slice(0, 1_000)
  end
end
