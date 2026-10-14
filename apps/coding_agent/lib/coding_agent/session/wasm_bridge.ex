defmodule CodingAgent.Session.WasmBridge do
  @moduledoc """
  Integrates the WASM sidecar runtime with the session.

  Handles starting/stopping the WASM sidecar process, discovering and building
  WASM tool inventories, reloading tools, host tool invocation routing, and
  WASM status/policy reporting.
  """

  require Logger

  alias CodingAgent.Wasm.Config, as: WasmConfig
  alias CodingAgent.Wasm.SidecarSession
  alias CodingAgent.Wasm.SidecarSupervisor
  alias CodingAgent.Wasm.ToolFactory
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult

  @host_timeout_ms 120_000

  @secret_exists_target "__lemon.secret.exists"
  @secret_resolve_target "__lemon.secret.resolve"

  # ============================================================================
  # Sidecar Lifecycle
  # ============================================================================

  @spec maybe_start_wasm_sidecar(
          String.t(),
          CodingAgent.SettingsManager.t(),
          String.t(),
          map() | nil,
          map() | nil
        ) :: map()
  def maybe_start_wasm_sidecar(cwd, settings_manager, session_id, tool_policy, approval_context) do
    wasm_config = WasmConfig.load(cwd, settings_manager)

    if wasm_config.enabled do
      session_pid = self()

      host_invoke_fun = fn tool_name, params_json, context ->
        invoke_host_request(session_pid, tool_name, params_json, context)
      end

      sidecar_opts = [
        cwd: cwd,
        session_id: session_id,
        settings_manager: settings_manager,
        wasm_config: wasm_config,
        host_invoke_fun: host_invoke_fun
      ]

      case start_wasm_sidecar_process(sidecar_opts) do
        {:ok, sidecar_pid} ->
          case SidecarSession.discover(sidecar_pid) do
            {:ok, discover} ->
              wasm_tools =
                ToolFactory.build_inventory(sidecar_pid, discover.tools,
                  cwd: cwd,
                  session_id: session_id
                )

              wasm_tool_names = Enum.map(wasm_tools, &elem(&1, 0))

              wasm_status =
                SidecarSession.status(sidecar_pid)
                |> Map.put(:discover_warnings, discover.warnings)
                |> Map.put(:discover_errors, discover.errors)
                |> Map.put(:tool_names, wasm_tool_names)
                |> Map.put(:policy, summarize_wasm_policy(tool_policy, approval_context))

              %{
                sidecar_pid: sidecar_pid,
                wasm_tools: wasm_tools,
                wasm_tool_names: wasm_tool_names,
                wasm_status: wasm_status
              }

            {:error, reason} ->
              _ = SidecarSupervisor.stop_sidecar(sidecar_pid)

              Logger.warning(
                "WASM runtime unavailable for session #{session_id}: #{inspect(reason)}"
              )

              %{
                sidecar_pid: nil,
                wasm_tools: [],
                wasm_tool_names: [],
                wasm_status: wasm_disabled_status(reason)
              }
          end

        {:error, reason} ->
          Logger.warning("WASM runtime unavailable for session #{session_id}: #{inspect(reason)}")

          %{
            sidecar_pid: nil,
            wasm_tools: [],
            wasm_tool_names: [],
            wasm_status: wasm_disabled_status(reason)
          }
      end
    else
      %{
        sidecar_pid: nil,
        wasm_tools: [],
        wasm_tool_names: [],
        wasm_status: wasm_disabled_status(:disabled_in_config)
      }
    end
  end

  @spec reload_wasm_tools(map()) :: map()
  def reload_wasm_tools(state) do
    cond do
      is_pid(state.wasm_sidecar_pid) and Process.alive?(state.wasm_sidecar_pid) ->
        case SidecarSession.discover(state.wasm_sidecar_pid) do
          {:ok, discover} ->
            wasm_tools =
              ToolFactory.build_inventory(state.wasm_sidecar_pid, discover.tools,
                cwd: state.cwd,
                session_id: state.session_manager.header.id
              )

            wasm_tool_names = Enum.map(wasm_tools, &elem(&1, 0))

            wasm_status =
              SidecarSession.status(state.wasm_sidecar_pid)
              |> Map.put(:discover_warnings, discover.warnings)
              |> Map.put(:discover_errors, discover.errors)
              |> Map.put(:tool_names, wasm_tool_names)
              |> Map.put(
                :policy,
                summarize_wasm_policy(state.tool_policy, state.approval_context)
              )

            %{
              sidecar_pid: state.wasm_sidecar_pid,
              wasm_tools: wasm_tools,
              wasm_tool_names: wasm_tool_names,
              wasm_status: wasm_status
            }

          {:error, reason} ->
            Logger.warning("WASM discover failed during reload: #{inspect(reason)}")

            %{
              sidecar_pid: state.wasm_sidecar_pid,
              wasm_tools: [],
              wasm_tool_names: [],
              wasm_status:
                (state.wasm_status || %{})
                |> Map.put(:discover_errors, [to_string(reason)])
                |> Map.put(:tool_names, [])
            }
        end

      true ->
        maybe_start_wasm_sidecar(
          state.cwd,
          state.settings_manager,
          state.session_manager.header.id,
          state.tool_policy,
          state.approval_context
        )
    end
  end

  @spec start_wasm_sidecar_process(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_wasm_sidecar_process(opts) do
    case SidecarSupervisor.start_sidecar(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # WASM Policy & Status
  # ============================================================================

  @spec summarize_wasm_policy(map() | nil, map() | nil) :: map()
  def summarize_wasm_policy(nil, _approval_context), do: %{approval_wrapping: false}

  def summarize_wasm_policy(tool_policy, approval_context) do
    %{
      approval_wrapping: not is_nil(approval_context),
      require_approval:
        Map.get(tool_policy, :require_approval) || Map.get(tool_policy, "require_approval"),
      approvals: Map.get(tool_policy, :approvals) || Map.get(tool_policy, "approvals")
    }
  end

  @spec wasm_disabled_status(term()) :: map()
  def wasm_disabled_status(reason) do
    %{
      enabled: false,
      running: false,
      hello_ok: false,
      runtime_path: nil,
      tool_count: 0,
      tool_names: [],
      discover_warnings: [],
      discover_errors: [inspect(reason)],
      reason: reason
    }
  end

  # ============================================================================
  # Host Tool Handling
  # ============================================================================
  @doc false
  def invoke_host_tool(session, tool_name, params_json, timeout_ms \\ @host_timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    context = %{
      deadline: System.monotonic_time(:millisecond) + min(timeout_ms, @host_timeout_ms),
      owner: self(),
      signal: nil
    }

    invoke_host_request(session, tool_name, params_json, context)
  end

  @doc false
  def invoke_host_request(session, tool_name, params_json, context) do
    GenServer.call(session, {:wasm_host_tool_invoke, tool_name, params_json, context}, :infinity)
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  @doc false
  def start_host_call(state, from, tool_name, params_json, context) do
    deadline = min(context.deadline, System.monotonic_time(:millisecond) + @host_timeout_ms)
    signal = context.signal
    request = %{from: from, owner: context.owner, signal: signal, deadline: deadline}

    case host_request_status(request) do
      {:error, _} = error ->
        {:reply, error, state}

      :ok ->
        # Capture the already policy/approval/plan-wrapped closure, never a fresh
        # registry lookup. Execution must not occupy the journal-owning GenServer.
        tool = find_host_tool(state, tool_name)

        case start_host_worker(tool_name, params_json, tool, signal) do
          {:ok, task} ->
            caller_ref = Process.monitor(elem(from, 0))
            owner_ref = Process.monitor(request.owner)
            timer = host_check_timer(task.ref, deadline)

            request =
              Map.merge(request, %{
                task: task,
                caller_ref: caller_ref,
                owner_ref: owner_ref,
                timer: timer
              })

            {:noreply,
             %{state | wasm_host_calls: Map.put(state.wasm_host_calls, task.ref, request)}}

          {:error, _} ->
            {:reply, {:error, :host_worker_unavailable}, state}
        end
    end
  end

  @doc false
  def finish_host_call(state, ref, result) do
    case Map.fetch(state.wasm_host_calls, ref) do
      {:ok, request} ->
        result =
          case host_request_status(request) do
            :ok -> result
            {:error, _} = error -> error
          end

        cleanup_host_call(request, result)
        GenServer.reply(request.from, result)
        %{state | wasm_host_calls: Map.delete(state.wasm_host_calls, ref)}

      :error ->
        state
    end
  end

  @doc false
  def check_host_call(state, ref) do
    case Map.fetch(state.wasm_host_calls, ref) do
      {:ok, request} ->
        case host_request_status(request) do
          :ok ->
            timer = host_check_timer(ref, request.deadline)
            request = %{request | timer: timer}
            %{state | wasm_host_calls: Map.put(state.wasm_host_calls, ref, request)}

          {:error, _} = error ->
            finish_host_call(state, ref, error)
        end

      :error ->
        state
    end
  end

  @doc false
  def host_call_down(state, ref) do
    case Enum.find(state.wasm_host_calls, fn {task_ref, request} ->
           task_ref == ref or request.caller_ref == ref or request.owner_ref == ref
         end) do
      {task_ref, _request} ->
        {:handled, finish_host_call(state, task_ref, {:error, :host_tool_failed})}

      nil ->
        :unhandled
    end
  end

  @doc false
  def cancel_host_calls(state, reason) do
    Enum.reduce(Map.keys(state.wasm_host_calls), state, fn ref, state ->
      finish_host_call(state, ref, {:error, reason})
    end)
  end

  @doc false
  def host_mutation_allowed?(state, {pid, _tag}) do
    # A timed-out/killed worker may already have queued its journal call.
    # Reject it even when the timeout/DOWN cleanup ran before this message.
    Process.alive?(pid) and
      Enum.all?(state.wasm_host_calls, fn {_ref, request} ->
        request.task.pid != pid or host_request_status(request) == :ok
      end)
  end

  defp host_request_status(request) do
    cond do
      not Process.alive?(elem(request.from, 0)) -> {:error, :caller_down}
      not Process.alive?(request.owner) -> {:error, :caller_down}
      System.monotonic_time(:millisecond) >= request.deadline -> {:error, :timeout}
      AbortSignal.aborted?(request.signal) -> {:error, :aborted}
      true -> :ok
    end
  end

  defp host_check_timer(ref, deadline) do
    delay = min(25, max(0, deadline - System.monotonic_time(:millisecond)))
    Process.send_after(self(), {:wasm_host_check, ref}, delay)
  end

  defp start_host_worker(tool_name, params_json, tool, signal) do
    # Linked as well as supervised: abnormal Session death kills the worker;
    # normal shutdown explicitly cancels all requests in Session.terminate/2.
    {:ok,
     Task.Supervisor.async(CodingAgent.TaskSupervisor, fn ->
       try do
         case maybe_handle_reserved_host_target(tool_name, params_json) do
           :not_reserved -> execute_host_tool(tool, params_json, signal)
           result -> result
         end
       rescue
         _ -> {:error, :host_tool_failed}
       catch
         _, _ -> {:error, :host_tool_failed}
       end
     end)}
  catch
    :exit, _ -> {:error, :host_worker_unavailable}
  end

  defp execute_host_tool(nil, _params_json, _signal), do: {:error, :tool_not_found}

  defp execute_host_tool(tool, params_json, signal) do
    params = decode_wasm_params(params_json)
    call_id = "wasm_host_#{System.unique_integer([:positive, :monotonic])}"

    case tool.execute.(call_id, params, signal, nil) do
      %AgentToolResult{} = result -> host_tool_result(result)
      {:ok, %AgentToolResult{} = result} -> host_tool_result(result)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_host_tool_result}
    end
  end

  defp host_tool_result(%AgentToolResult{is_error: true} = result),
    do: {:error, encode_wasm_host_output(result)}

  defp host_tool_result(%AgentToolResult{} = result),
    do: {:ok, encode_wasm_host_output(result)}

  defp cleanup_host_call(request, result) do
    if is_reference(request.signal) and
         result in [
           {:error, :timeout},
           {:error, :aborted},
           {:error, :caller_down},
           {:error, :session_unavailable}
         ] do
      AbortSignal.abort(request.signal)
    end

    monitor = Process.monitor(request.task.pid)
    Process.exit(request.task.pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    end

    Process.demonitor(request.task.ref, [:flush])
    Process.demonitor(request.caller_ref, [:flush])
    Process.demonitor(request.owner_ref, [:flush])
    Process.cancel_timer(request.timer)
  end

  @spec maybe_handle_reserved_host_target(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()} | :not_reserved
  def maybe_handle_reserved_host_target(@secret_exists_target, params_json) do
    params = decode_wasm_params(params_json)

    case extract_secret_name(params) do
      {:ok, secret_name} ->
        exists? = LemonCore.Secrets.exists?(secret_name, prefer_env: false, env_fallback: true)
        {:ok, Jason.encode!(%{"exists" => exists?})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def maybe_handle_reserved_host_target(@secret_resolve_target, params_json) do
    params = decode_wasm_params(params_json)

    case extract_secret_name(params) do
      {:ok, secret_name} ->
        case LemonCore.Secrets.resolve(secret_name, prefer_env: false, env_fallback: true) do
          {:ok, value, source} ->
            {:ok, Jason.encode!(%{"value" => value, "source" => to_string(source)})}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def maybe_handle_reserved_host_target(_tool_name, _params_json), do: :not_reserved

  @spec find_host_tool(map(), String.t()) :: LemonAgent.Types.AgentTool.t() | nil
  def find_host_tool(state, tool_name) when is_binary(tool_name) do
    Enum.find(state.tools, fn tool ->
      tool.name == tool_name and tool.name not in state.wasm_tool_names
    end)
  end

  def find_host_tool(_state, _tool_name), do: nil

  @spec decode_wasm_params(String.t() | term()) :: map()
  def decode_wasm_params(params_json) when is_binary(params_json) do
    case Jason.decode(params_json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def decode_wasm_params(_), do: %{}

  @spec encode_wasm_host_output(LemonAgent.Types.AgentToolResult.t()) :: String.t()
  def encode_wasm_host_output(%LemonAgent.Types.AgentToolResult{} = tool_result) do
    payload =
      cond do
        is_map(tool_result.details) and map_size(tool_result.details) > 0 ->
          tool_result.details

        true ->
          %{"text" => extract_text_from_tool_result(tool_result.content)}
      end

    Jason.encode!(payload)
  end

  # ---- Private helpers ----

  defp extract_secret_name(params) when is_map(params) do
    value = params["name"] || params[:name]

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, :invalid_secret_name}
    end
  end

  defp extract_text_from_tool_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_text_from_tool_result(_), do: ""
end
