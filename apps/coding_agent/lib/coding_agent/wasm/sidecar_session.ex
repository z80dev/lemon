defmodule CodingAgent.Wasm.SidecarSession do
  @moduledoc """
  Per-session client for the Rust WASM sidecar runtime.

  The session owns the port and WASM protocol state; `LemonCore.Rpc.Client`
  owns framing, pending callers and request deadlines. Public calls return
  `{:error, :timeout}` when their deadline expires, even while a host callback
  is running. Late responses cannot complete a later invocation.
  Parent-intent scopes remain local invocation metadata, forwarded only to the
  trusted host callback and never encoded into sidecar JSON.
  """

  use GenServer
  require Logger

  alias CodingAgent.Wasm.Builder
  alias CodingAgent.Wasm.Config
  alias CodingAgent.Wasm.Protocol
  alias LemonAgent.AbortSignal
  alias LemonCore.Rpc.Client, as: RpcClient

  defmodule Framing do
    @moduledoc false
    @behaviour LemonCore.Rpc.Framing

    @impl true
    def encode(message), do: LemonCore.Rpc.JsonLines.encode(message)

    @impl true
    def decode(buffer), do: decode_lines(buffer, [])

    defp decode_lines(buffer, messages) do
      case :binary.match(buffer, "\n") do
        {offset, 1} ->
          <<line::binary-size(^offset), "\n", rest::binary>> = buffer

          case String.trim(line) do
            "" ->
              decode_lines(rest, messages)

            line ->
              case Protocol.decode_line(line) do
                {:ok, message} ->
                  decode_lines(rest, [message | messages])

                {:error, _reason} ->
                  Logger.warning("WASM sidecar protocol parse error")
                  decode_lines(rest, messages)
              end
          end

        :nomatch ->
          {:ok, Enum.reverse(messages), buffer}
      end
    end
  end

  @discover_timeout 60_000
  @invoke_timeout 120_000

  @type discovered_tool :: %{
          name: String.t(),
          path: String.t(),
          description: String.t(),
          schema_json: String.t(),
          capabilities: map(),
          auth: map() | nil,
          warnings: [String.t()]
        }

  @type discover_result :: %{
          tools: [discovered_tool()],
          warnings: [String.t()],
          errors: [String.t()]
        }

  @type invoke_result :: %{
          output_json: String.t() | nil,
          error: String.t() | nil,
          logs: [map()],
          details: map()
        }

  @type status :: %{
          enabled: boolean(),
          runtime_path: String.t() | nil,
          hello_ok: boolean(),
          running: boolean(),
          tool_count: non_neg_integer(),
          discover_warnings: [String.t()],
          discover_errors: [String.t()],
          build: map() | nil
        }

  defstruct [
    :session_id,
    :cwd,
    :config,
    :runtime_path,
    :build_report,
    :port,
    :rpc_client,
    :rpc_monitor,
    :host_invoke_fun,
    :hello_id,
    :hello_ok,
    :invocation,
    :discovered,
    :discover_warnings,
    :discover_errors
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          config: Config.t(),
          runtime_path: String.t() | nil,
          build_report: map() | nil,
          port: port() | nil,
          rpc_client: pid(),
          rpc_monitor: reference(),
          host_invoke_fun: function(),
          hello_id: String.t() | nil,
          hello_ok: boolean(),
          invocation: map() | nil,
          discovered: [discovered_tool()],
          discover_warnings: [String.t()],
          discover_errors: [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec discover(pid(), timeout()) :: {:ok, discover_result()} | {:error, term()}
  def discover(pid, timeout \\ @discover_timeout) do
    started_at_ms = now_ms()
    deadline = request_deadline(timeout, @discover_timeout)

    case GenServer.call(pid, {:discover, deadline}, :infinity) do
      {:discover_response, result, metadata} ->
        LemonCore.Telemetry.emit(
          [:lemon, :wasm, :discover, :stop],
          %{duration_ms: now_ms() - started_at_ms, ok: match?({:ok, _}, result)},
          metadata
        )

        result

      result ->
        result
    end
  end

  @spec invoke(pid(), String.t(), String.t(), String.t() | nil, timeout(), reference() | nil) ::
          {:ok, invoke_result()} | {:error, term()}
  def invoke(
        pid,
        tool,
        params_json,
        context_json \\ nil,
        timeout \\ @invoke_timeout,
        signal \\ nil
      ) do
    started_at_ms = now_ms()
    deadline = request_deadline(timeout, @invoke_timeout)
    scope = CodingAgent.ToolIntent.current_parent_scope()

    case GenServer.call(
           pid,
           {:invoke, tool, params_json, context_json, deadline, signal, scope},
           :infinity
         ) do
      {:invoke_response, result, metadata} ->
        LemonCore.Telemetry.emit(
          [:lemon, :wasm, :invoke, :stop],
          %{duration_ms: now_ms() - started_at_ms, ok: match?({:ok, _}, result)},
          metadata
        )

        result

      result ->
        result
    end
  end

  @spec status(pid()) :: status()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl true
  def init(opts) do
    cwd = opts |> Keyword.fetch!(:cwd) |> Path.expand()
    session_id = to_string(Keyword.get(opts, :session_id, "unknown"))

    case validate_cwd(cwd) do
      :ok ->
        config =
          Keyword.get_lazy(opts, :wasm_config, fn ->
            Config.load(cwd, Keyword.get(opts, :settings_manager))
          end)

        host_invoke_fun = Keyword.get(opts, :host_invoke_fun, &default_host_invoke/2)

        with {:ok, runtime_path, build_report} <- Builder.ensure_runtime_binary(config),
             {:ok, port} <- start_port(runtime_path, cwd),
             {:ok, rpc_client} <-
               RpcClient.start_link(
                 owner: self(),
                 framing: Framing,
                 send: fn bytes ->
                   if Port.command(port, bytes), do: :ok, else: {:error, :send_failed}
                 end
               ) do
          state = %__MODULE__{
            session_id: session_id,
            cwd: cwd,
            config: config,
            runtime_path: runtime_path,
            build_report: build_report,
            port: port,
            rpc_client: rpc_client,
            rpc_monitor: Process.monitor(rpc_client),
            host_invoke_fun: host_invoke_fun,
            hello_id: nil,
            hello_ok: false,
            invocation: nil,
            discovered: [],
            discover_warnings: [],
            discover_errors: []
          }

          {:ok, send_hello(state)}
        else
          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp validate_cwd(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call({:discover, deadline}, from, state) do
    cond do
      expired?(deadline) ->
        {:reply, {:error, :timeout}, state}

      not is_port(state.port) ->
        {:reply, {:error, :runtime_not_running}, state}

      true ->
        payload = %{
          "paths" => state.config.discover_paths,
          "defaults" => %{
            "default_memory_limit" => state.config.default_memory_limit,
            "default_timeout_ms" => state.config.default_timeout_ms,
            "default_fuel_limit" => state.config.default_fuel_limit,
            "cache_compiled" => state.config.cache_compiled,
            "cache_dir" => state.config.cache_dir,
            "max_tool_invoke_depth" => state.config.max_tool_invoke_depth
          }
        }

        LemonCore.Telemetry.emit(
          [:lemon, :wasm, :discover, :start],
          %{count: 1},
          discover_metadata(state)
        )

        case dispatch(state, "discover", payload, from, deadline) do
          {:ok, _id} -> {:noreply, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:invoke, _tool, _params_json, _context_json, _deadline, _signal, _scope},
        _from,
        %{invocation: invocation} = state
      )
      when not is_nil(invocation) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(
        {:invoke, tool, params_json, context_json, deadline, signal, scope},
        from,
        state
      ) do
    AbortSignal.subscribe(signal)

    cond do
      not Process.alive?(elem(from, 0)) or AbortSignal.aborted?(signal) ->
        AbortSignal.unsubscribe(signal)
        {:reply, {:error, :aborted}, state}

      expired?(deadline) ->
        AbortSignal.unsubscribe(signal)
        {:reply, {:error, :timeout}, state}

      not is_port(state.port) ->
        AbortSignal.unsubscribe(signal)
        {:reply, {:error, :runtime_not_running}, state}

      true ->
        payload = %{
          "tool" => tool,
          "params_json" => params_json,
          "context_json" => context_json
        }

        LemonCore.Telemetry.emit([:lemon, :wasm, :invoke, :start], %{count: 1}, %{
          host: :wasm,
          session_hash: hash_value(state.session_id),
          cwd_hash: hash_value(state.cwd),
          tool_hash: hash_value(tool)
        })

        case dispatch(state, "invoke", payload, from, deadline) do
          {:ok, request_id} ->
            invocation = %{
              id: request_id,
              tool: tool,
              owner: elem(from, 0),
              deadline: deadline,
              signal: signal,
              parent_intent_scope: scope,
              started_at_ms: now_ms()
            }

            {:noreply, %{state | invocation: invocation}}

          {:error, reason} ->
            AbortSignal.unsubscribe(signal)
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    RpcClient.feed(state.rpc_client, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:sidecar_exit, status}
    Logger.warning("WASM sidecar exited for session #{state.session_id}: #{inspect(reason)}")

    RpcClient.fail_all(state.rpc_client, {:error, reason})
    {:stop, reason, %{state | port: nil}}
  end

  def handle_info({:rpc_message, %{"type" => "response"} = message}, state) do
    {:noreply, handle_response(state, message)}
  end

  def handle_info({:rpc_message, %{"type" => "event", "event" => "host_call"} = message}, state) do
    {:noreply, handle_host_call_event(state, message)}
  end

  def handle_info({:rpc_finished, id, reason}, %{invocation: %{id: id}} = state) do
    {:noreply, finish_invocation(state, reason)}
  end

  def handle_info({:lemon_abort, signal, :abort}, %{invocation: %{signal: signal}} = state) do
    RpcClient.complete(state.rpc_client, state.invocation.id, {:error, :aborted})
    {:noreply, finish_invocation(state, :aborted)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{rpc_monitor: ref} = state) do
    {:stop, :connection_closed, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.invocation, do: AbortSignal.unsubscribe(state.invocation.signal)

    try do
      if state.port, do: send_message(state, "shutdown", %{})
      RpcClient.fail_all(state.rpc_client, {:error, :connection_closed})
      :gen_statem.stop(state.rpc_client)
    catch
      :exit, _ -> :ok
    end

    if state.port do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp start_port(runtime_path, cwd) do
    opts = [
      :stream,
      :binary,
      :exit_status,
      :use_stdio,
      {:cd, cwd}
    ]

    port = LemonCore.NativeProcess.open({:spawn_executable, runtime_path}, opts)
    {:ok, port}
  rescue
    error -> {:error, {:port_start_failed, error}}
  end

  defp send_hello(state) do
    id = Protocol.next_id("hello")
    RpcClient.send_message(state.rpc_client, request("hello", id, %{"version" => 1}))
    %{state | hello_id: id}
  end

  defp dispatch(state, type, payload, from, deadline) do
    id = Protocol.next_id(type)

    case RpcClient.dispatch(
           state.rpc_client,
           id,
           request(type, id, payload),
           from,
           remaining_timeout(deadline)
         ) do
      :ok -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp send_message(state, type, payload) do
    RpcClient.send_message(state.rpc_client, request(type, Protocol.next_id(type), payload))
  end

  defp request(type, id, payload) do
    payload |> Map.put("type", type) |> Map.put("id", id)
  end

  defp handle_response(state, %{"id" => id, "ok" => ok} = msg)
       when id == state.hello_id do
    if not ok do
      Logger.warning("WASM sidecar hello failed for session #{state.session_id}: #{msg["error"]}")
    end

    %{state | hello_ok: ok, hello_id: nil}
  end

  defp handle_response(state, %{"id" => "discover_" <> _ = id, "ok" => ok} = msg) do
    result =
      if ok,
        do: {:ok, normalize_discover_result(msg["result"])},
        else: {:error, msg["error"] || "discover_failed"}

    case RpcClient.complete(
           state.rpc_client,
           id,
           {:discover_response, result, discover_metadata(state)}
         ) do
      :ok ->
        case result do
          {:ok, discovered} ->
            %{
              state
              | discovered: discovered.tools,
                discover_warnings: discovered.warnings,
                discover_errors: discovered.errors
            }

          {:error, error} ->
            %{state | discover_errors: [error | state.discover_errors]}
        end

      {:error, :not_found} ->
        state
    end
  end

  defp handle_response(%{invocation: %{id: id}} = state, %{"id" => id, "ok" => ok} = msg) do
    result =
      if ok,
        do: {:ok, normalize_invoke_result(msg["result"])},
        else: {:error, msg["error"] || "invoke_failed"}

    metadata = Map.put(discover_metadata(state), :tool_hash, hash_value(state.invocation.tool))

    case RpcClient.complete(state.rpc_client, id, {:invoke_response, result, metadata}) do
      :ok -> finish_invocation(state, :response)
      {:error, :not_found} -> state
    end
  end

  defp handle_response(state, _msg), do: state

  defp handle_host_call_event(
         %{invocation: %{id: request_id} = invocation} = state,
         %{
           "request_id" => request_id,
           "call_id" => call_id,
           "tool" => tool,
           "params_json" => params_json
         }
       ) do
    response_payload =
      case invoke_host_for_request(state.host_invoke_fun, invocation, tool, params_json) do
        {:ok, output_json} ->
          %{
            "call_id" => call_id,
            "ok" => true,
            "output_json" => output_json,
            "error" => nil
          }

        {:error, reason} ->
          %{
            "call_id" => call_id,
            "ok" => false,
            "output_json" => nil,
            "error" => host_error_text(reason)
          }
      end

    send_message(state, "host_call_result", response_payload)
    state
  end

  defp handle_host_call_event(state, _msg), do: state

  defp invoke_host_for_request(fun, invocation, tool, params_json) do
    cond do
      not Process.alive?(invocation.owner) or AbortSignal.aborted?(invocation.signal) ->
        {:error, :aborted}

      expired?(invocation.deadline) ->
        {:error, :timeout}

      true ->
        context = Map.take(invocation, [:owner, :deadline, :signal, :parent_intent_scope])

        safe_host_invoke(
          fn name, params ->
            if is_function(fun, 3), do: fun.(name, params, context), else: fun.(name, params)
          end,
          tool,
          params_json
        )
    end
  end

  defp host_error_text(reason) when is_binary(reason), do: reason
  defp host_error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp host_error_text(_reason), do: "host_tool_failed"

  defp safe_host_invoke(fun, tool, params_json) when is_function(fun, 2) do
    try do
      case fun.(tool, params_json) do
        {:ok, output_json} when is_binary(output_json) -> {:ok, output_json}
        {:ok, nil} -> {:ok, "null"}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_host_invoke_result, other}}
      end
    rescue
      error -> {:error, error}
    catch
      :exit, _ -> {:error, :host_invoke_unavailable}
    end
  end

  defp normalize_discover_result(result) when is_map(result) do
    tools =
      result
      |> Map.get("tools", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn tool ->
        %{
          name: to_string(tool["name"] || ""),
          path: to_string(tool["path"] || ""),
          description: to_string(tool["description"] || ""),
          schema_json: to_string(tool["schema_json"] || "{}"),
          capabilities: normalize_capabilities(tool["capabilities"] || %{}),
          auth: normalize_auth_metadata(tool["auth"]),
          warnings: normalize_string_list(tool["warnings"] || [])
        }
      end)
      |> Enum.reject(&(&1.name == ""))

    %{
      tools: tools,
      warnings: normalize_string_list(result["warnings"] || []),
      errors: normalize_string_list(result["errors"] || [])
    }
  end

  defp normalize_discover_result(_),
    do: %{tools: [], warnings: [], errors: ["invalid_discover_result"]}

  defp normalize_invoke_result(result) when is_map(result) do
    %{
      output_json: normalize_optional_string(result["output_json"]),
      error: normalize_optional_string(result["error"]),
      logs: normalize_logs(result["logs"] || []),
      details: result["details"] || %{}
    }
  end

  defp normalize_invoke_result(_),
    do: %{output_json: nil, error: "invalid_invoke_result", logs: [], details: %{}}

  defp normalize_logs(logs) when is_list(logs) do
    Enum.filter(logs, &is_map/1)
  end

  defp normalize_logs(_), do: []

  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    %{
      workspace_read: truthy?(capabilities["workspace_read"] || capabilities[:workspace_read]),
      http: truthy?(capabilities["http"] || capabilities[:http]),
      tool_invoke: truthy?(capabilities["tool_invoke"] || capabilities[:tool_invoke]),
      secrets: truthy?(capabilities["secrets"] || capabilities[:secrets]),
      auth: truthy?(capabilities["auth"] || capabilities[:auth]),
      exec: truthy?(capabilities["exec"] || capabilities[:exec])
    }
  end

  defp normalize_capabilities(_),
    do: %{
      workspace_read: false,
      http: false,
      tool_invoke: false,
      secrets: false,
      auth: false,
      exec: false
    }

  defp normalize_auth_metadata(nil), do: nil

  defp normalize_auth_metadata(auth) when is_map(auth) do
    secret_name = auth["secret_name"] || auth[:secret_name]

    if is_binary(secret_name) and String.trim(secret_name) != "" do
      %{
        secret_name: String.trim(secret_name),
        display_name: normalize_optional_string(auth["display_name"] || auth[:display_name]),
        instructions: normalize_optional_string(auth["instructions"] || auth[:instructions]),
        setup_url: normalize_optional_string(auth["setup_url"] || auth[:setup_url]),
        token_hint: normalize_optional_string(auth["token_hint"] || auth[:token_hint]),
        env_var: normalize_optional_string(auth["env_var"] || auth[:env_var]),
        provider: normalize_optional_string(auth["provider"] || auth[:provider]),
        has_oauth: truthy?(auth["has_oauth"] || auth[:has_oauth])
      }
    else
      nil
    end
  end

  defp normalize_auth_metadata(_), do: nil

  defp normalize_string_list(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_), do: []

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: to_string(value)

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp hash_value(nil), do: nil

  defp hash_value(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(value), do: value |> inspect() |> hash_value()

  defp build_status(state) do
    %{
      enabled: state.config.enabled,
      runtime_path: state.runtime_path,
      hello_ok: state.hello_ok,
      running: is_port(state.port),
      tool_count: length(state.discovered),
      discover_warnings: state.discover_warnings,
      discover_errors: state.discover_errors,
      build: state.build_report
    }
  end

  defp discover_metadata(state) do
    %{
      host: :wasm,
      session_hash: hash_value(state.session_id),
      cwd_hash: hash_value(state.cwd)
    }
  end

  defp finish_invocation(state, reason) do
    invocation = state.invocation
    AbortSignal.unsubscribe(invocation.signal)

    if reason != :response do
      LemonCore.Telemetry.emit(
        [:lemon, :wasm, :invoke, :stop],
        %{duration_ms: now_ms() - invocation.started_at_ms, ok: false},
        Map.put(discover_metadata(state), :tool_hash, hash_value(invocation.tool))
      )
    end

    %{state | invocation: nil}
  end

  defp request_deadline(:infinity, _default), do: :infinity
  defp request_deadline(timeout, _default) when is_integer(timeout), do: now_ms() + timeout
  defp request_deadline(_timeout, default), do: now_ms() + default

  defp remaining_timeout(:infinity), do: :infinity
  defp remaining_timeout(deadline), do: max(deadline - now_ms(), 0)

  defp expired?(:infinity), do: false
  defp expired?(deadline), do: now_ms() >= deadline

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp default_host_invoke(_tool, _params_json), do: {:error, :host_invoke_not_configured}
end
