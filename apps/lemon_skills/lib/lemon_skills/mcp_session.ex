defmodule LemonSkills.McpSession do
  @moduledoc """
  Volatile, owner-bound MCP connections keyed by an opaque session identifier.

  `open/4` validates all definitions before starting any client, then requires
  every handshake and tool discovery to succeed. Definitions are ACP JSON maps:
  stdio `name`, `command`, `args`, `env`, or HTTP/SSE `type`, `name`, `url`,
  `headers`. Environment/header entries accept name/value arrays or JSON maps.
  Shared configuration options, including stdio `cwd`, OAuth and sampling,
  retain the same parser and validation as configured servers. Session
  definitions default to requiring approval; local per-tool policy is exposed
  separately from untrusted remote tool metadata.

  No definitions or credentials are persisted. Existing OAuth token-secret
  references can be read, but token exchanges never install a save callback.
  Closing, replacing, or losing the owner releases every connection.
  Missing sessions return empty tools/policies.
  Errors are classified atoms and never contain configuration or client output.
  """

  use GenServer

  alias LemonSkills.{Config, McpSource}

  @supervisor LemonSkills.McpSession.Supervisor

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec open(term(), String.t(), [map()], pid()) :: :ok | {:error, atom()}
  def open(id, cwd, configs, owner_pid) do
    with :ok <- validate_identity(id, cwd, owner_pid),
         {:ok, configs} <- normalize_configs(configs) do
      request({:open, id, Path.expand(cwd), configs, owner_pid}, {:error, :runtime_unavailable})
    end
  end

  @doc """
  Attach profile streamable-HTTP definitions (`name`, `url`, `headers`, `enabledTools`).

  `enabledTools` is an exact allowlist of raw remote names: omitted allows all,
  `[]` allows none. An explicit list also disables resource/prompt utilities.
  The execution request may use atom or JSON keys. Profile definitions cannot
  select stdio, OAuth persistence or paths.
  Profile tools use stable public-endpoint aliases and defer approval requirements
  to the native tool-policy floor. Generic `open/4`/ACP sessions keep their local
  approval metadata and legacy aliases.
  `${LEMON_SECRET:NAME}` header references resolve only through the encrypted
  secret store on this executing host, immediately before client attachment.
  Missing or failing reads fail closed; no environment expansion is performed.
  Credentials remain volatile and errors never include a definition or value.
  """
  @spec open_http(term(), String.t(), [map()], pid()) :: :ok | {:error, atom()}
  def open_http(id, cwd, configs, owner_pid) when is_list(configs) do
    configs =
      Enum.map(configs, fn
        raw when is_map(raw) ->
          config = %{
            "type" => "http",
            "name" => Map.get(raw, "name", Map.get(raw, :name)),
            "url" => Map.get(raw, "url", Map.get(raw, :url)),
            "headers" => Map.get(raw, "headers", Map.get(raw, :headers, %{}))
          }

          Enum.reduce(
            [
              {"enabledTools", :enabledTools},
              {"allowedOrigins", :allowedOrigins},
              {"approvedPrivateOrigins", :approvedPrivateOrigins}
            ],
            config,
            fn {key, atom}, config ->
              if Map.has_key?(raw, key) or Map.has_key?(raw, atom),
                do: Map.put(config, key, Map.get(raw, key, Map.get(raw, atom))),
                else: config
            end
          )

        _ ->
          nil
      end)

    with :ok <- validate_identity(id, cwd, owner_pid),
         {:ok, configs} <- normalize_configs(configs),
         {:ok, configs} <- pin_http_destinations(configs),
         {:ok, configs} <- resolve_http_secrets(configs) do
      configs =
        Enum.map(configs, fn {:http, url, opts} ->
          {:http, url, Keyword.put(opts, :profile_owned, true)}
        end)

      request({:open, id, Path.expand(cwd), configs, owner_pid}, {:error, :runtime_unavailable})
    end
  end

  def open_http(_id, _cwd, _configs, _owner_pid), do: {:error, :invalid_config}

  defp pin_http_destinations(configs) do
    Enum.reduce_while(configs, {:ok, []}, fn {:http, url, opts} = config, {:ok, acc} ->
      case Keyword.fetch(opts, :origin_policy) do
        :error ->
          {:cont, {:ok, [config | acc]}}

        {:ok, policy} ->
          module = Module.concat(["Lemon" <> "MCP", "HTTP", "OriginPolicy"])

          case apply(module, :pin, [url, policy]) do
            {:ok, pin} ->
              {:cont, {:ok, [{:http, url, Keyword.put(opts, :destination_pin, pin)} | acc]}}

            {:error, reason} when is_atom(reason) ->
              {:halt, {:error, reason}}

            _ ->
              {:halt, {:error, :destination_not_allowed}}
          end
      end
    end)
    |> case do
      {:ok, configs} -> {:ok, Enum.reverse(configs)}
      error -> error
    end
  rescue
    _ -> {:error, :destination_not_allowed}
  catch
    _, _ -> {:error, :destination_not_allowed}
  end

  defp resolve_http_secrets(configs) do
    Enum.reduce_while(configs, {:ok, []}, fn {:http, url, opts}, {:ok, acc} ->
      case resolve_http_headers(Keyword.get(opts, :headers, [])) do
        {:ok, headers, values} ->
          opts = opts |> Keyword.put(:headers, headers) |> Keyword.put(:redact_values, values)
          {:cont, {:ok, [{:http, url, opts} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, configs} -> {:ok, Enum.reverse(configs)}
      error -> error
    end
  end

  defp resolve_http_headers(headers) do
    Enum.reduce_while(headers, {:ok, [], []}, fn {name, value}, {:ok, acc, values} ->
      case resolve_header(value) do
        {:ok, resolved, secrets} ->
          {:cont, {:ok, [{name, resolved} | acc], [value, resolved | secrets] ++ values}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, headers, values} -> {:ok, Enum.reverse(headers), Enum.uniq(values)}
      error -> error
    end
  end

  defp resolve_header(value) do
    with {:ok, parts, secrets} <- resolve_header_segments(value, [], []),
         resolved <- parts |> Enum.reverse() |> IO.iodata_to_binary(),
         true <-
           byte_size(resolved) <= 8_192 and String.valid?(resolved) and
             not String.contains?(resolved, ["\r", "\n", <<0>>]) do
      {:ok, resolved, secrets}
    else
      _ -> {:error, :secret_resolution_failed}
    end
  rescue
    _ -> {:error, :secret_resolution_failed}
  catch
    _, _ -> {:error, :secret_resolution_failed}
  end

  defp resolve_header_segments(value, parts, secrets) do
    case :binary.match(value, "${LEMON_SECRET:") do
      :nomatch ->
        {:ok, [value | parts], secrets}

      {offset, size} ->
        prefix = binary_part(value, 0, offset)
        rest = binary_part(value, offset + size, byte_size(value) - offset - size)

        case :binary.match(rest, "}") do
          {length, 1} when length > 0 ->
            name = binary_part(rest, 0, length)
            tail = binary_part(rest, length + 1, byte_size(rest) - length - 1)

            with true <-
                   name == String.trim(name) and byte_size(name) <= 512 and
                     not String.contains?(name, ["{", "\r", "\n", <<0>>]),
                 {:ok, secret} when is_binary(secret) <- LemonCore.Secrets.get(name) do
              resolve_header_segments(tail, [secret, prefix | parts], [secret, name | secrets])
            else
              _ -> {:error, :secret_resolution_failed}
            end

          _ ->
            {:error, :secret_resolution_failed}
        end
    end
  end

  @spec tools(term()) :: [LemonAgent.Types.AgentTool.t()]
  def tools(id), do: request({:lookup, id, :tools}, [])

  @spec approvals(term()) :: %{String.t() => :always | :never}
  def approvals(id), do: request({:lookup, id, :approvals}, %{})

  @doc "Return credential-scrubbed raw remote tool descriptors through the owning source."
  @spec remote_tools(term()) :: {:ok, [map()]} | {:error, atom()}
  def remote_tools(id), do: request({:remote_tools, id}, {:error, :runtime_unavailable})

  @spec close(term()) :: :ok
  def close(id), do: request({:close, id}, :ok)

  defp request(message, fallback) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:open, id, cwd, configs, owner}, _from, state) do
    state = remove_session(state, id)

    if Process.alive?(owner) do
      spec =
        Supervisor.child_spec(
          {McpSource, name: nil, configs: configs, cwd: cwd, owner: owner, custodian: self()},
          restart: :temporary
        )

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, source} ->
          case discover(source) do
            {:ok, tools, approvals} ->
              if Process.alive?(owner) and Process.alive?(source) do
                session = %{
                  source: source,
                  source_ref: Process.monitor(source),
                  owner: owner,
                  owner_ref: Process.monitor(owner),
                  tools: tools,
                  approvals: approvals
                }

                {:reply, :ok, Map.put(state, id, session)}
              else
                stop_source(source)
                {:reply, {:error, :owner_unavailable}, state}
              end

            {:error, reason} ->
              stop_source(source)
              {:reply, {:error, reason}, state}
          end

        _ ->
          {:reply, {:error, :connection_failed}, state}
      end
    else
      {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:lookup, id, key}, _from, state) do
    default = if key == :tools, do: [], else: %{}

    case Map.get(state, id) do
      nil ->
        {:reply, default, state}

      session ->
        if Process.alive?(session.owner) and Process.alive?(session.source) do
          {:reply, Map.fetch!(session, key), state}
        else
          {:reply, default, remove_session(state, id)}
        end
    end
  end

  def handle_call({:remote_tools, id}, _from, state) do
    case Map.get(state, id) do
      %{source: source, owner: owner} ->
        if Process.alive?(owner) and Process.alive?(source) do
          {:reply, McpSource.remote_tools(source), state}
        else
          {:reply, {:error, :owner_unavailable}, remove_session(state, id)}
        end

      nil ->
        {:reply, {:error, :discovery_failed}, state}
    end
  end

  def handle_call({:close, id}, _from, state) do
    {:reply, :ok, remove_session(state, id)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state, state, fn {id, session}, acc ->
        if ref in [session.owner_ref, session.source_ref], do: remove_session(acc, id), else: acc
      end)

    {:noreply, state}
  end

  defp discover(source) do
    case McpSource.discover_ready(source) do
      {:ok, tools} ->
        {:ok, tools, McpSource.approval_policy(source)}

      {:error, reason} when reason in [:mcp_disabled, :connection_failed, :discovery_failed] ->
        {:error, reason}

      _ ->
        {:error, :discovery_failed}
    end
  catch
    :exit, _ -> {:error, :discovery_failed}
  end

  defp remove_session(state, id) do
    case Map.pop(state, id) do
      {nil, state} ->
        state

      {session, state} ->
        Process.demonitor(session.owner_ref, [:flush])
        Process.demonitor(session.source_ref, [:flush])
        stop_source(session.source)
        state
    end
  end

  defp stop_source(source) do
    DynamicSupervisor.terminate_child(@supervisor, source)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp validate_identity(id, cwd, owner) do
    cond do
      not (is_binary(id) and byte_size(id) > 0) ->
        {:error, :invalid_id}

      not (is_binary(cwd) and String.valid?(cwd) and cwd != "" and
               not String.contains?(cwd, <<0>>)) ->
        {:error, :invalid_cwd}

      not (is_pid(owner) and node(owner) == node()) ->
        {:error, :invalid_owner}

      not Process.alive?(owner) ->
        {:error, :owner_unavailable}

      true ->
        :ok
    end
  end

  defp normalize_configs(configs) when is_list(configs) do
    Enum.reduce_while(configs, {:ok, [], MapSet.new()}, fn raw, {:ok, acc, names} ->
      with {:ok, config, name} <- normalize_config(raw),
           false <- MapSet.member?(names, name) do
        {:cont, {:ok, [config | acc], MapSet.put(names, name)}}
      else
        _ -> {:halt, {:error, :invalid_config}}
      end
    end)
    |> case do
      {:ok, configs, _names} -> {:ok, Enum.reverse(configs)}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_config}
  end

  defp normalize_configs(_), do: {:error, :invalid_config}

  defp normalize_config(raw) when is_map(raw) do
    name = Map.get(raw, "name")
    type = Map.get(raw, "type", "stdio")

    with true <- is_binary(name) and String.valid?(name) and String.trim(name) != "",
         true <- type in ["stdio", "http", "sse"],
         true <- valid_transport?(raw, type),
         true <- valid_connection_options?(raw),
         {:ok, env} <- pairs(Map.get(raw, "env", %{})),
         {:ok, headers} <- pairs(Map.get(raw, "headers", %{})),
         :ok <- validate_enabled_tools(raw),
         :ok <- validate_origin_policy(raw) do
      normalized =
        raw
        |> Map.put("type", type)
        |> Map.put("env", env)
        |> Map.put("headers", headers)
        |> Map.put_new("approval", "always")

      with [config] <- Config.parse_mcp_server_config(normalized),
           :ok <- McpSource.validate_config(config) do
        {:ok, volatile_config(config), name}
      else
        _ -> {:error, :invalid_config}
      end
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp normalize_config(_), do: {:error, :invalid_config}

  defp validate_enabled_tools(raw) do
    if not Map.has_key?(raw, "enabledTools") or
         (is_list(raw["enabledTools"]) and length(raw["enabledTools"]) <= 256 and
            Enum.all?(raw["enabledTools"], &McpSource.valid_remote_name?/1) and
            MapSet.size(MapSet.new(raw["enabledTools"])) == length(raw["enabledTools"])) do
      :ok
    else
      {:error, :invalid_config}
    end
  end

  defp validate_origin_policy(raw) do
    if Enum.all?(["allowedOrigins", "approvedPrivateOrigins"], fn key ->
         not Map.has_key?(raw, key) or
           (is_list(raw[key]) and length(raw[key]) <= 32 and Enum.all?(raw[key], &valid_string?/1))
       end),
       do: :ok,
       else: {:error, :invalid_config}
  end

  defp valid_connection_options?(raw) do
    cwd_valid? =
      not Map.has_key?(raw, "cwd") or
        (valid_string?(raw["cwd"]) and String.trim(raw["cwd"]) != "")

    cwd_valid? and
      Enum.all?(["oauth", "sampling"], fn key ->
        not Map.has_key?(raw, key) or is_map(raw[key])
      end)
  end

  defp volatile_config({:http, url, opts}),
    do: {:http, url, Keyword.put(opts, :volatile_credentials, true)}

  defp volatile_config(config), do: config

  defp valid_transport?(raw, "stdio") do
    command = Map.get(raw, "command")
    args = Map.get(raw, "args", [])

    valid_string?(command) and String.trim(command) != "" and is_list(args) and
      Enum.all?(args, &valid_string?/1)
  end

  defp valid_transport?(raw, _type), do: valid_string?(Map.get(raw, "url"))

  defp pairs(values) when is_map(values) do
    if Enum.all?(values, fn {name, value} -> valid_pair?(name, value) end),
      do: {:ok, values},
      else: {:error, :invalid_config}
  end

  defp pairs(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn
      %{"name" => name, "value" => value}, {:ok, acc} ->
        if valid_pair?(name, value) and not Map.has_key?(acc, name),
          do: {:cont, {:ok, Map.put(acc, name, value)}},
          else: {:halt, {:error, :invalid_config}}

      _, _ ->
        {:halt, {:error, :invalid_config}}
    end)
  end

  defp pairs(_), do: {:error, :invalid_config}

  defp valid_pair?(name, value), do: valid_string?(name) and name != "" and valid_string?(value)

  defp valid_string?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)
end
