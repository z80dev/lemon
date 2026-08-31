defmodule CodingAgent.ExecutionNode.Worker do
  @moduledoc """
  Native worker for a named Lemon execution node.

  The worker authenticates to a controller, accepts targeted
  `coding_agent.run` invocations, and executes them through the existing
  `CodingAgent.Executor`. It never forwards the node selector into the local
  session, preventing a remote run from recursively selecting itself.
  """

  use GenServer

  require Logger

  alias CodingAgent.ExecutionNode.{Codec, Socket, TokenStore}
  alias LemonGateway.ExecutionRequest

  @protocol_version 1
  @max_control_text_bytes 16 * 1_024
  @capabilities %{
    "coding_agent.run" => %{"version" => @protocol_version},
    "node.invoke.control" => %{
      "version" => @protocol_version,
      "operations" => ["steer", "redirect"],
      "maxTextBytes" => @max_control_text_bytes
    },
    "node.invoke.cancel" => true
  }

  defstruct [
    :name,
    :controller,
    :default_cwd,
    :socket,
    :socket_module,
    :socket_opts,
    :socket_mode,
    :executor_module,
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
       socket_module: Keyword.get(opts, :socket_module, Socket),
       socket_opts: Keyword.get(opts, :socket_opts, []),
       executor_module: Keyword.get(opts, :executor_module, CodingAgent.Executor),
       token_store_module: Keyword.get(opts, :token_store_module, TokenStore),
       token_store_opts: Keyword.get(opts, :token_store_opts, []),
       notify_pid: Keyword.get(opts, :notify_pid),
       requested_node_id: Keyword.get(opts, :node_id),
       repair: Keyword.get(opts, :repair, false),
       max_payload_bytes: LemonCore.JSONPayload.default_max_bytes()
     }}
  end

  defp connect_initial(state, opts) do
    if Keyword.get(opts, :pair, false) do
      with {:ok, state} <- prepare_pairing_identity(state) do
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
      %{
        "role" => "operator",
        "client" => %{"id" => "lemon-execution-node-pair:#{state.name}"}
      }
      |> maybe_put_auth(operator_token)

    start_socket(state, :pairing, connect_params)
  end

  defp connect_authenticated(state, token, expected_node_id) do
    connect_params = %{
      "auth" => %{"token" => token},
      "client" => %{"id" => "lemon-execution-node:#{state.name}"}
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
          _ = state.executor_module.cancel(invocation.context)

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

          {:noreply, %{state | invocations: invocations}}
        end
    end
  end

  def handle_info({:engine_event, run_ref, %{__event__: :completed} = completed}, state) do
    case Map.get(state.run_refs, run_ref) do
      nil -> {:noreply, state}
      invoke_id -> {:noreply, complete_invocation(state, invoke_id, completed)}
    end
  end

  def handle_info({:engine_event, _run_ref, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Enum.find(state.invocations, fn {_id, invocation} ->
           invocation.monitor_ref == monitor_ref
         end) do
      {invoke_id, _invocation} ->
        state = send_invoke_error(state, invoke_id, {:runner_down, reason})
        {:noreply, remove_invocation(state, invoke_id)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, socket, reason}, %{socket: socket} = state) do
    {:stop, {:socket_exited, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

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

      case connect_authenticated(%{state | socket: nil, pairing_stage: nil}, token, node_id) do
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

  defp handle_socket_response(_tag, _result, state), do: {:noreply, state}

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
        "capabilities" => @capabilities
      }
      |> maybe_put_recovery(state)

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

        Map.has_key?(state.invocations, invoke_id) ->
          {:noreply, state}

        method != "coding_agent.run" ->
          {:noreply, send_invoke_error(state, invoke_id, {:unsupported_method, method})}

        not is_map(args) ->
          {:noreply, send_invoke_error(state, invoke_id, :invalid_arguments)}

        payload_error = validate_payload(args, state) ->
          {:noreply, send_invoke_error(state, invoke_id, payload_error)}

        true ->
          {:noreply, start_invocation(state, invoke_id, args)}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_node_event("node.invoke.cancel", payload, state) do
    invoke_id = payload["invokeId"]

    case Map.get(state.invocations, invoke_id) do
      nil ->
        {:noreply, state}

      invocation ->
        _ = state.executor_module.cancel(invocation.context)
        {:noreply, remove_invocation(state, invoke_id)}
    end
  end

  defp handle_node_event("node.invoke.control", payload, state) do
    if targeted?(payload, state) do
      {:noreply, apply_invocation_control(state, payload)}
    else
      {:noreply, state}
    end
  end

  defp handle_node_event(_event, _payload, state), do: {:noreply, state}

  defp start_invocation(state, invoke_id, args) do
    with {:ok, request, run_opts} <- execution_request(args, state, invoke_id),
         {:ok, run_ref, context} <-
           state.executor_module.start_run(request, run_opts, self()) do
      runner_pid = Map.get(context, :runner_pid)
      monitor_ref = if is_pid(runner_pid), do: Process.monitor(runner_pid)

      invocation = %{
        run_ref: run_ref,
        context: context,
        monitor_ref: monitor_ref,
        deltas: [],
        delta_bytes: 0,
        delta_count: 0,
        run_id: request.run_id
      }

      %{
        state
        | invocations: Map.put(state.invocations, invoke_id, invocation),
          run_refs: Map.put(state.run_refs, run_ref, invoke_id)
      }
    else
      {:error, reason} -> send_invoke_error(state, invoke_id, reason)
    end
  end

  @doc false
  @spec execution_request(map(), struct(), String.t()) ::
          {:ok, ExecutionRequest.t(), map()} | {:error, term()}
  def execution_request(args, state, invoke_id) when is_map(args) do
    version = value(args, "version")
    prompt = value(args, "prompt")
    requested_cwd = value(args, "cwd")

    with :ok <- validate_version(version),
         {:ok, prompt} <- nonempty(prompt, :missing_prompt),
         {:ok, cwd} <- invocation_cwd(requested_cwd, state.default_cwd) do
      run_id = optional_string(value(args, "runId")) || "node:#{invoke_id}"
      session_key = optional_string(value(args, "sessionKey")) || "node:#{state.name}:#{run_id}"
      meta = args |> value("meta") |> normalize_meta()

      request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        images: normalize_images(value(args, "images")),
        cwd: cwd,
        resume: normalize_resume(value(args, "resume")),
        lane: value(args, "lane"),
        tool_policy: normalize_tool_policy(value(args, "toolPolicy")),
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

    case LemonCore.JSONPayload.validate(params, max_bytes: result_content_limit(state)) do
      {:ok, _stats} ->
        request(state, "node.invoke.result", params, {:invoke_result, invoke_id})

      {:error, _reason} ->
        send_invoke_error(state, invoke_id, :result_payload_limit_exceeded)
    end

    remove_invocation(state, invoke_id)
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
    case LemonCore.JSONPayload.validate(args, max_bytes: payload_limit(state)) do
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

  defp validate_version(@protocol_version), do: :ok
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

  defp normalize_images(images) when is_list(images), do: Enum.filter(images, &is_map/1)
  defp normalize_images(_), do: []

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
      :thinking_level,
      :system_prompt,
      :agent_id,
      :resume_source,
      :acp_session_id,
      :acp_client_fs_read_text_file,
      :acp_client_fs_write_text_file,
      :async_followups
    ])
    |> normalize_thinking_level()
    |> normalize_resume_source()
  end

  defp normalize_meta(_), do: %{}

  defp normalize_thinking_level(meta) do
    allowed = %{
      "off" => :off,
      "minimal" => :minimal,
      "low" => :low,
      "medium" => :medium,
      "high" => :high,
      "xhigh" => :xhigh
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

  defp normalize_tool_policy(policy) when is_map(policy) do
    atomize_known_keys(policy, [
      :allow,
      :deny,
      :require_approval,
      :approvals,
      :no_reply,
      :profile
    ])
  end

  defp normalize_tool_policy(_), do: nil

  defp atomize_known_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.pop(acc, string_key) do
        {nil, acc} -> acc
        {value, acc} -> Map.put(acc, key, value)
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

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, key_atom(key))
  defp value(_map, _key), do: nil

  defp key_atom("version"), do: :version
  defp key_atom("runId"), do: :run_id
  defp key_atom("sessionKey"), do: :session_key
  defp key_atom("prompt"), do: :prompt
  defp key_atom("images"), do: :images
  defp key_atom("cwd"), do: :cwd
  defp key_atom("resume"), do: :resume
  defp key_atom("lane"), do: :lane
  defp key_atom("toolPolicy"), do: :tool_policy
  defp key_atom("meta"), do: :meta

  defp notify(%{notify_pid: pid}, message) when is_pid(pid) do
    send(pid, {:execution_node_worker, self(), message})
  end

  defp notify(_state, _message), do: :ok

  defp cancel_all_invocations(state) do
    Enum.each(state.invocations, fn {_invoke_id, invocation} ->
      _ = state.executor_module.cancel(invocation.context)

      if invocation.monitor_ref do
        Process.demonitor(invocation.monitor_ref, [:flush])
      end
    end)

    %{state | invocations: %{}, run_refs: %{}}
  end

  defp safe_reason(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 500)
    |> String.slice(0, 1_000)
  end
end
