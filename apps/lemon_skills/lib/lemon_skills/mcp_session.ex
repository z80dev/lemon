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
  Attachments run in supervised workers with a ten-minute total deadline;
  cached lookups and closes remain responsive during handshake or discovery.
  Closing/replacing a pending attachment or losing its owner/caller cancels it.
  Late results cannot restore a closed or replaced session.
  """

  use GenServer

  alias LemonSkills.{Config, McpSource}

  @supervisor LemonSkills.McpSession.Supervisor
  # Session attachment policy: ten minutes for the whole server set, including
  # OAuth/queueing. Cached management reads retain the OTP five-second deadline.
  @open_timeout_ms :timer.minutes(10)
  @read_timeout_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Attach explicit definitions for an owner-bound session.

  `project_trust: %{project:, digest:}` is internal provenance from
  `LemonSkills.McpConfig.fetch/2` for a project entry; it is never read from the
  definitions themselves. With it, every spawn and reconnect re-checks that the
  operator still trusts exactly that project content, so trust revoked between
  fetch and attach starts nothing.
  """
  @spec open(term(), String.t(), [map()], pid(), keyword()) :: :ok | {:error, atom()}
  def open(id, cwd, configs, owner_pid, opts \\ []) do
    with :ok <- validate_identity(id, cwd, owner_pid),
         {:ok, configs} <- normalize_configs(configs),
         {:ok, configs} <- bind_project(configs, Keyword.get(opts, :project_trust)) do
      request(
        {:open, id, Path.expand(cwd), configs, owner_pid},
        {:error, :runtime_unavailable},
        @open_timeout_ms + @read_timeout_ms
      )
    end
  end

  defp bind_project(configs, nil), do: {:ok, configs}

  defp bind_project(configs, %{project: project, digest: digest})
       when is_binary(project) and is_binary(digest) do
    provenance = %{project: project, digest: digest, external: false}

    {:ok,
     Enum.map(configs, fn
       {:stdio, command, args} ->
         {:stdio, command, args, [project_trust: provenance]}

       {:stdio, command, args, opts} ->
         {:stdio, command, args, opts ++ [project_trust: provenance]}

       {transport, url} ->
         {transport, url, [project_trust: provenance]}

       {transport, url, opts} ->
         {transport, url, opts ++ [project_trust: provenance]}
     end)}
  end

  defp bind_project(_configs, _provenance), do: {:error, :invalid_config}

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

      request(
        {:open, id, Path.expand(cwd), configs, owner_pid},
        {:error, :runtime_unavailable},
        @open_timeout_ms + @read_timeout_ms
      )
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
  def remote_tools(id) do
    case request({:source, id}, {:error, :runtime_unavailable}) do
      {:ok, source} -> McpSource.remote_tools(source)
      error -> error
    end
  end

  @spec close(term()) :: :ok | {:error, atom()}
  def close(id), do: request({:close, id}, :ok)

  defp request(message, fallback, timeout \\ @read_timeout_ms) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:open, id, cwd, configs, owner}, from, state) do
    state = remove_session(state, id)

    if Process.alive?(owner) do
      manager = self()
      token = make_ref()

      case start_task(fn -> open_source(manager, id, token, cwd, configs, owner) end) do
        {:ok, task} ->
          session = %{
            source: nil,
            source_ref: nil,
            owner: owner,
            owner_ref: Process.monitor(owner),
            caller_ref: Process.monitor(elem(from, 0)),
            task: task,
            token: token,
            timer: Process.send_after(self(), {:open_timeout, id, token}, @open_timeout_ms),
            from: from,
            tools: [],
            approvals: %{}
          }

          {:noreply, Map.put(state, id, session)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :owner_unavailable}, state}
    end
  end

  def handle_call({:attach_source, id, token, source}, _from, state) do
    case state[id] do
      %{token: ^token} = session ->
        session = %{session | source: source, source_ref: Process.monitor(source)}
        {:reply, :ok, Map.put(state, id, session)}

      _ ->
        {:reply, {:error, :session_closed}, state}
    end
  end

  def handle_call({:detach_source, id, token}, _from, state) do
    case state[id] do
      %{token: ^token} = session ->
        if session.source_ref, do: Process.demonitor(session.source_ref, [:flush])
        {:reply, :ok, Map.put(state, id, %{session | source_ref: nil})}

      _ ->
        {:reply, {:error, :session_closed}, state}
    end
  end

  def handle_call({:lookup, id, key}, _from, state) do
    default = if key == :tools, do: [], else: %{}

    case Map.get(state, id) do
      nil ->
        {:reply, default, state}

      %{task: _} ->
        {:reply, default, state}

      session ->
        if Process.alive?(session.owner) and Process.alive?(session.source) do
          {:reply, Map.fetch!(session, key), state}
        else
          {:reply, default, remove_session(state, id)}
        end
    end
  end

  def handle_call({:source, id}, _from, state) do
    case Map.get(state, id) do
      %{task: _} ->
        {:reply, {:error, :discovery_failed}, state}

      %{source: source, owner: owner} ->
        if Process.alive?(owner) and Process.alive?(source) do
          {:reply, {:ok, source}, state}
        else
          {:reply, {:error, :owner_unavailable}, remove_session(state, id)}
        end

      nil ->
        {:reply, {:error, :discovery_failed}, state}
    end
  end

  def handle_call({:close, id}, from, state) do
    source =
      case state[id] do
        %{source: source} -> source
        _ -> nil
      end

    state = remove_session(state, id)

    if source do
      # A close acknowledgement means the dynamic supervisor has removed the
      # child, not merely that a shutdown cast has reached the source mailbox.
      # Waiting happens in an owned worker so other session reads stay live.
      case start_task(fn ->
             stop_source(source)
             GenServer.reply(from, :ok)
           end) do
        {:ok, _task} -> {:noreply, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state, fn {_, session} -> session[:task] && session.task.ref == ref end) do
      nil ->
        {:noreply, state}

      {id, session} ->
        Process.demonitor(ref, [:flush])
        Process.demonitor(session.caller_ref, [:flush])
        Process.cancel_timer(session.timer)

        case result do
          {:ok, tools, approvals} when is_pid(session.source) ->
            if Process.alive?(session.owner) and Process.alive?(session.source) do
              GenServer.reply(session.from, :ok)

              session =
                session
                |> Map.drop([:task, :token, :timer, :from, :caller_ref])
                |> Map.merge(%{tools: tools, approvals: approvals})

              {:noreply, Map.put(state, id, session)}
            else
              {:noreply, remove_session(state, id, {:error, :owner_unavailable})}
            end

          {:error, reason} ->
            {:noreply, remove_session(state, id, {:error, reason})}
        end
    end
  end

  def handle_info({:open_timeout, id, token}, state) do
    case state[id] do
      %{token: ^token} -> {:noreply, remove_session(state, id, {:error, :timeout})}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state, state, fn {id, session}, acc ->
        refs = [
          session.owner_ref,
          session.source_ref,
          session[:caller_ref],
          session[:task] && session.task.ref
        ]

        if ref in refs, do: remove_session(acc, id, {:error, :owner_unavailable}), else: acc
      end)

    {:noreply, state}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state, fn {id, _} -> remove_session(state, id) end)
  end

  defp open_source(manager, id, token, cwd, configs, owner) do
    spec =
      Supervisor.child_spec(
        {McpSource, name: nil, configs: configs, cwd: cwd, owner: owner, custodian: self()},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, source} ->
        result =
          with :ok <- GenServer.call(manager, {:attach_source, id, token, source}),
               :ok <- GenServer.call(source, {:handoff_custodian, manager}),
               {:ok, _, _} = result <- discover(source) do
            result
          end

        case result do
          {:ok, _, _} ->
            result

          {:error, _} = error ->
            GenServer.call(manager, {:detach_source, id, token})
            stop_source(source)
            error
        end

      _ ->
        {:error, :connection_failed}
    end
  catch
    :exit, _ -> {:error, :connection_failed}
  end

  defp start_task(fun) do
    owner = self()

    {:ok,
     Task.Supervisor.async_nolink(LemonSkills.TaskSupervisor, fn ->
       Process.link(owner)
       fun.()
     end)}
  rescue
    RuntimeError -> {:error, :task_capacity_reached}
  catch
    :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
  end

  defp discover(source) do
    case McpSource.discover_ready(source) do
      {:ok, tools} ->
        {:ok, tools, McpSource.approval_policy(source)}

      {:error, reason}
      when reason in [
             :mcp_disabled,
             :connection_failed,
             :discovery_failed,
             :timeout,
             :task_capacity_reached,
             :task_supervisor_unavailable,
             :project_untrusted
           ] ->
        {:error, reason}

      _ ->
        {:error, :discovery_failed}
    end
  catch
    :exit, _ -> {:error, :discovery_failed}
  end

  defp remove_session(state, id, reply \\ {:error, :session_closed}) do
    case Map.pop(state, id) do
      {nil, state} ->
        state

      {session, state} ->
        Process.demonitor(session.owner_ref, [:flush])
        if session.source_ref, do: Process.demonitor(session.source_ref, [:flush])

        if session[:task] do
          Process.exit(session.task.pid, :kill)
          Process.demonitor(session.task.ref, [:flush])
          Process.demonitor(session.caller_ref, [:flush])
          Process.cancel_timer(session.timer)
          GenServer.reply(session.from, reply)
        end

        if session.source, do: GenServer.cast(session.source, :close)
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
