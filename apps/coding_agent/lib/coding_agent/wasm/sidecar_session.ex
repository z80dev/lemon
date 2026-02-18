defmodule CodingAgent.Wasm.SidecarSession do
  @moduledoc """
  Per-session client for the Rust WASM sidecar runtime.
  """

  use GenServer
  require Logger

  alias CodingAgent.Wasm.Builder
  alias CodingAgent.Wasm.Config
  alias CodingAgent.Wasm.Protocol

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
    :buffer,
    :host_invoke_fun,
    :hello_ok,
    :inflight_invoke_id,
    :discovered,
    :discover_warnings,
    :discover_errors,
    :pending
  ]

  @type pending_kind :: :hello | :discover | {:invoke, String.t()} | :host_call_result | :shutdown

  @type pending_request :: %{
          from: GenServer.from() | nil,
          kind: pending_kind(),
          started_at_ms: integer()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          config: Config.t(),
          runtime_path: String.t() | nil,
          build_report: map() | nil,
          port: port() | nil,
          buffer: String.t(),
          host_invoke_fun: (String.t(), String.t() -> {:ok, String.t()} | {:error, term()}),
          hello_ok: boolean(),
          inflight_invoke_id: String.t() | nil,
          discovered: [discovered_tool()],
          discover_warnings: [String.t()],
          discover_errors: [String.t()],
          pending: %{String.t() => pending_request()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec discover(pid(), timeout()) :: {:ok, discover_result()} | {:error, term()}
  def discover(pid, timeout \\ @discover_timeout) do
    GenServer.call(pid, :discover, timeout)
  end

  @spec invoke(pid(), String.t(), String.t(), String.t() | nil, timeout()) ::
          {:ok, invoke_result()} | {:error, term()}
  def invoke(pid, tool, params_json, context_json \\ nil, timeout \\ @invoke_timeout) do
    GenServer.call(pid, {:invoke, tool, params_json, context_json}, timeout)
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

    config =
      Keyword.get_lazy(opts, :wasm_config, fn ->
        Config.load(cwd, Keyword.get(opts, :settings_manager))
      end)

    host_invoke_fun = Keyword.get(opts, :host_invoke_fun, &default_host_invoke/2)

    with {:ok, runtime_path, build_report} <- Builder.ensure_runtime_binary(config),
         {:ok, port} <- start_port(runtime_path, cwd) do
      state = %__MODULE__{
        session_id: session_id,
        cwd: cwd,
        config: config,
        runtime_path: runtime_path,
        build_report: build_report,
        port: port,
        buffer: "",
        host_invoke_fun: host_invoke_fun,
        hello_ok: false,
        inflight_invoke_id: nil,
        discovered: [],
        discover_warnings: [],
        discover_errors: [],
        pending: %{}
      }

      {:ok, send_hello(state)}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:discover, from, state) do
    if not is_port(state.port) do
      {:reply, {:error, :runtime_not_running}, state}
    else
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

      LemonCore.Telemetry.emit([:lemon, :wasm, :discover, :start], %{count: 1}, %{
        session_id: state.session_id,
        cwd: state.cwd
      })

      {:noreply, send_request(state, "discover", payload, from, :discover)}
    end
  end

  def handle_call(
        {:invoke, _tool, _params_json, _context_json},
        _from,
        %{inflight_invoke_id: id} = state
      )
      when is_binary(id) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:invoke, tool, params_json, context_json}, from, state) do
    if not is_port(state.port) do
      {:reply, {:error, :runtime_not_running}, state}
    else
      payload = %{
        "tool" => tool,
        "params_json" => params_json,
        "context_json" => context_json
      }

      LemonCore.Telemetry.emit([:lemon, :wasm, :invoke, :start], %{count: 1}, %{
        session_id: state.session_id,
        tool: tool
      })

      {state, request_id} = send_request_with_id(state, "invoke", payload, from, {:invoke, tool})
      {:noreply, %{state | inflight_invoke_id: request_id}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = process_port_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:sidecar_exit, status}
    Logger.warning("WASM sidecar exited for session #{state.session_id}: #{inspect(reason)}")

    state =
      Enum.reduce(state.pending, state, fn {_id, pending}, acc ->
        reply_pending(pending.from, {:error, reason})
        acc
      end)

    {:stop, reason, %{state | port: nil, pending: %{}, inflight_invoke_id: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      _ = send_request(state, "shutdown", %{}, nil, :shutdown)

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

    port = Port.open({:spawn_executable, runtime_path}, opts)
    {:ok, port}
  rescue
    error -> {:error, {:port_start_failed, error}}
  end

  defp send_hello(state) do
    payload = %{"version" => 1}
    send_request(state, "hello", payload, nil, :hello)
  end

  defp send_request_with_id(%__MODULE__{port: port} = state, type, payload, from, kind)
       when is_port(port) do
    id = Protocol.next_id(type)
    encoded = Protocol.encode_request(type, id, payload)

    true = Port.command(port, encoded)

    pending_entry = %{from: from, kind: kind, started_at_ms: now_ms()}
    state = %{state | pending: Map.put(state.pending, id, pending_entry)}

    {state, id}
  end

  defp send_request_with_id(state, _type, _payload, _from, _kind), do: {state, nil}

  defp send_request(%__MODULE__{port: port} = state, type, payload, from, kind)
       when is_port(port) do
    {state, _id} = send_request_with_id(state, type, payload, from, kind)
    state
  end

  defp send_request(state, _type, _payload, _from, _kind), do: state

  defp process_port_data(state, data) when is_binary(data) do
    {lines, remainder} = split_complete_lines(state.buffer <> data)

    state =
      Enum.reduce(lines, %{state | buffer: remainder}, fn line, acc ->
        handle_protocol_line(acc, line)
      end)

    %{state | buffer: remainder}
  end

  defp split_complete_lines(buffer) do
    parts = String.split(buffer, "\n", trim: false)

    case parts do
      [] -> {[], ""}
      [_single] -> {[], buffer}
      _ -> {Enum.slice(parts, 0, length(parts) - 1), List.last(parts)}
    end
  end

  defp handle_protocol_line(state, line) do
    line = String.trim(line)

    if line == "" do
      state
    else
      case Protocol.decode_line(line) do
        {:ok, %{"type" => "response"} = msg} ->
          handle_response(state, msg)

        {:ok, %{"type" => "event", "event" => "host_call"} = msg} ->
          handle_host_call_event(state, msg)

        {:ok, _other} ->
          state

        {:error, reason} ->
          Logger.warning("WASM sidecar protocol parse error: #{inspect(reason)}")
          state
      end
    end
  end

  defp handle_response(state, %{"id" => id, "ok" => ok} = msg) do
    {pending, pending_map} = Map.pop(state.pending, id)

    if is_nil(pending) do
      state
    else
      duration_ms = now_ms() - pending.started_at_ms

      case pending.kind do
        :hello ->
          if not ok do
            Logger.warning(
              "WASM sidecar hello failed for session #{state.session_id}: #{msg["error"]}"
            )
          end

          %{state | hello_ok: ok, pending: pending_map}

        :discover ->
          LemonCore.Telemetry.emit(
            [:lemon, :wasm, :discover, :stop],
            %{duration_ms: duration_ms, ok: ok},
            %{
              session_id: state.session_id,
              cwd: state.cwd
            }
          )

          state = %{state | pending: pending_map}

          if ok do
            result = normalize_discover_result(msg["result"])
            reply_pending(pending.from, {:ok, result})

            %{
              state
              | discovered: result.tools,
                discover_warnings: result.warnings,
                discover_errors: result.errors
            }
          else
            reply_pending(pending.from, {:error, msg["error"] || "discover_failed"})

            %{
              state
              | discover_errors: [msg["error"] || "discover_failed" | state.discover_errors]
            }
          end

        {:invoke, tool} ->
          LemonCore.Telemetry.emit(
            [:lemon, :wasm, :invoke, :stop],
            %{duration_ms: duration_ms, ok: ok},
            %{
              session_id: state.session_id,
              tool: tool
            }
          )

          state = %{state | pending: pending_map, inflight_invoke_id: nil}

          if ok do
            reply_pending(pending.from, {:ok, normalize_invoke_result(msg["result"])})
            state
          else
            reply_pending(pending.from, {:error, msg["error"] || "invoke_failed"})
            state
          end

        :host_call_result ->
          %{state | pending: pending_map}

        :shutdown ->
          reply_pending(pending.from, :ok)
          %{state | pending: pending_map}
      end
    end
  end

  defp handle_response(state, _msg), do: state

  defp handle_host_call_event(state, %{
         "call_id" => call_id,
         "tool" => tool,
         "params_json" => params_json
       }) do
    response_payload =
      case safe_host_invoke(state.host_invoke_fun, tool, params_json) do
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
            "error" => to_string(reason)
          }
      end

    send_request(state, "host_call_result", response_payload, nil, :host_call_result)
  end

  defp handle_host_call_event(state, _msg), do: state

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
    end
  end

  defp safe_host_invoke(_fun, _tool, _params_json), do: {:error, :host_invoke_unavailable}

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
      auth: truthy?(capabilities["auth"] || capabilities[:auth])
    }
  end

  defp normalize_capabilities(_),
    do: %{workspace_read: false, http: false, tool_invoke: false, secrets: false, auth: false}

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

  defp reply_pending(nil, _reply), do: :ok

  defp reply_pending(from, reply) do
    GenServer.reply(from, reply)
  rescue
    _ -> :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp default_host_invoke(_tool, _params_json), do: {:error, :host_invoke_not_configured}
end
