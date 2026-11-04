defmodule CodingAgent.Session.AddressingContext do
  @moduledoc false

  alias CodingAgent.{Config, Session, SessionManager}
  alias CodingAgent.Tools.Task.Params
  alias LemonCore.{ChatStateStore, ProfileStore, ResumeToken, RunStore, SessionKey}

  @max_directories 4_096
  @max_header_bytes 65_536
  @max_journal_bytes 32 * 1_024 * 1_024

  # This lookup accepts an identity, never a caller-selected workspace or file.
  # A registered root owns live authority. Cold recovery only considers native
  # journals immediately below the configured sessions root, and binds the exact
  # ChatState token to the header before inspecting the matching journal.
  def resolve(key, owners) when is_binary(key) do
    with :ok <- local_root_key(key),
         {:ok, roots, children} <- live_roots(key, owners) do
      case roots do
        [state] -> live_context(key, state)
        [] -> cold_context(key, children)
        _ -> {:error, :context_unavailable}
      end
    end
  rescue
    _ -> {:error, :context_unavailable}
  catch
    :exit, _ -> {:error, :context_unavailable}
  end

  def resolve(_, _), do: {:error, :context_unavailable}

  defp local_root_key(key) do
    case SessionKey.parse(key) do
      %{kind: :main, agent_id: id} when id != "" ->
        :ok

      %{channel_id: channel, agent_id: id}
      when channel in ["fork", "tui", "local"] and id != "" ->
        :ok

      _ ->
        {:error, :forbidden}
    end
  end

  defp live_roots(key, owners) do
    Enum.reduce_while(owners, {:ok, [], []}, fn {id, pid}, {:ok, roots, children} ->
      case Session.get_state(pid) do
        %{session_key: ^key, session_manager: %{header: %{id: ^id}}, task_child: true} ->
          {:cont, {:ok, roots, [id | children]}}

        %{session_key: ^key, session_manager: %{header: %{id: ^id}}, task_child: false} = state ->
          {:cont, {:ok, [state | roots], children}}

        _ ->
          {:halt, {:error, :context_unavailable}}
      end
    end)
  end

  defp live_context(key, state) do
    opts = Map.new(state.tool_opts || [])
    authority = Map.merge(opts, state.approval_context || %{})
    servers = authority[:invocation_mcp_servers] || authority[:mcp_servers]

    with :ok <- ordinary_authority(authority, servers),
         {:ok, cwd} <- existing_cwd(state.cwd),
         true <- state.session_manager.header.cwd == cwd do
      meta =
        %{}
        |> put_optional(:invocation_context_key, authority[:invocation_context_key])
        |> put_optional(:mcp_servers, servers)

      context(cwd, state.session_manager.header.id)
      |> put_optional(:tool_policy, state.tool_policy)
      |> Map.put(:meta, meta)
      |> with_profile(key, authority[:native_source_profile_id] || authority[:profile_id])
    else
      false -> {:error, :context_unavailable}
      error -> error
    end
  end

  defp ordinary_authority(authority, servers) do
    # Lifecycle inserts nil/false placeholders even for direct ordinary sessions.
    # They are not evidence of managed origin; a real proof/lineage or a positive
    # memory grant is. An explicit managed flag remains authoritative.
    meaningful =
      Map.reject(authority, fn {key, value} ->
        is_nil(value) or
          (key in [:memory_context_verified, :shared_memory_grant] and value == false)
      end)

    if Params.managed_context?(meaningful) or
         Params.managed_metadata?(%{mcp_servers: servers}) do
      {:error, :forbidden}
    else
      :ok
    end
  end

  defp cold_context(key, children) do
    with {:ok, token} <- native_token(key),
         :ok <- if(token in children, do: {:error, :forbidden}, else: :ok),
         {:ok, root} <- canonical_directory(Path.join(Config.agent_dir(), "sessions")),
         {:ok, path, header} <- find_journal(root, token),
         {:ok, session} <- SessionManager.load_from_file(path),
         true <- session.header.id == token and session.header.cwd == header["cwd"],
         {:ok, execution} <- SessionManager.execution_context(session),
         :ok <- cold_authority(key, execution),
         {:ok, cwd} <- existing_cwd(header["cwd"]) do
      context(cwd, token)
      |> put_optional(:tool_policy, execution && execution.tool_policy)
      |> with_profile(key, nil)
    else
      {:error, :forbidden} = error -> error
      _ -> {:error, :context_unavailable}
    end
  end

  defp native_token(key) do
    case ChatStateStore.get(key) do
      state when is_map(state) ->
        token = field(state, :last_resume_token)

        if field(state, :last_engine) == "lemon" and is_binary(token) and
             byte_size(token) in 1..512 and String.valid?(token) and
             not String.contains?(token, ["/", "\\", <<0>>]) and token not in [".", ".."] do
          {:ok, token}
        else
          {:error, :context_unavailable}
        end

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp cold_authority(_key, nil), do: :ok

  defp cold_authority(key, execution) do
    origin = execution.provenance.origin

    if (execution.parent_run_id != nil and origin != "fork") or
         origin in ["task", "subagent", "lemon_bot"] do
      {:error, :forbidden}
    else
      # Older native journals contain execution authority, not the admitted
      # command. Inspect associated run metadata only to refuse managed lineage;
      # never return its persisted credentials, MCP configuration or proof.
      case RunStore.fetch(execution.run_id) do
        {:ok, nil} ->
          :ok

        {:ok, record} ->
          summary = field(record, :summary) || %{}
          meta = field(summary, :meta) || %{}
          recorded_key = field(summary, :session_key)

          cond do
            recorded_key not in [nil, key] ->
              {:error, :context_unavailable}

            field(meta, :native_managed_context) == true or Params.managed_metadata?(meta) ->
              {:error, :forbidden}

            true ->
              :ok
          end

        _ ->
          {:error, :context_unavailable}
      end
    end
  end

  defp context(cwd, token) do
    %{cwd: cwd, task_child: false, resume: ResumeToken.new("lemon", token)}
  end

  defp with_profile(context, _key, profile_id) when is_binary(profile_id) and profile_id != "" do
    {:ok, Map.put(context, :profile_id, profile_id)}
  end

  defp with_profile(context, key, _) do
    case ProfileStore.get(SessionKey.agent_id(key)) do
      {:ok, %{"id" => id, "canonicalSessionKey" => ^key}} ->
        {:ok, Map.put(context, :profile_id, id)}

      {:error, :not_found} ->
        {:ok, context}

      {:error, :invalid_id} ->
        {:ok, context}

      {:ok, _} ->
        {:ok, context}

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp find_journal(root, token) do
    # Native filenames may be hashes of non-portable IDs. Use the owner's naming
    # rule, not a token interpolated into a caller-supplied path.
    basename = Path.basename(SessionManager.session_file_path(root, token))

    with {:ok, directories} <- File.ls(root),
         true <- length(directories) <= @max_directories do
      directories
      |> Enum.reduce_while({:ok, []}, fn directory, {:ok, matches} ->
        path = Path.join([root, directory, basename])

        case journal_candidate(root, directory, path, token) do
          :absent -> {:cont, {:ok, matches}}
          {:ok, header} -> {:cont, {:ok, [{path, header} | matches]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, [{path, header}]} -> {:ok, path, header}
        _ -> {:error, :context_unavailable}
      end
    else
      _ -> {:error, :context_unavailable}
    end
  end

  defp journal_candidate(root, directory, path, token) do
    # Do not follow symlinked buckets, journal symlinks or special files. Even a
    # corrupt file bearing the requested filename prevents an ambiguous recovery.
    case File.lstat(Path.join(root, directory)) do
      {:ok, %{type: :directory}} ->
        case File.lstat(path) do
          {:error, :enoent} ->
            :absent

          {:ok, %{type: :regular, size: size}} when size <= @max_journal_bytes ->
            with {:ok, header} <- read_header(path),
                 %{"type" => "session", "id" => ^token, "cwd" => cwd} <- header,
                 true <- is_binary(cwd) and Path.type(cwd) == :absolute,
                 true <- Path.basename(Config.sessions_dir(cwd)) == directory,
                 version when version in 1..3 <- header["version"] || 1 do
              {:ok, header}
            else
              _ -> {:error, :context_unavailable}
            end

          _ ->
            {:error, :context_unavailable}
        end

      {:ok, %{type: type}} when type in [:symlink, :regular] ->
        :absent

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp read_header(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case :file.read(file, @max_header_bytes) do
            {:ok, bytes} ->
              case :binary.split(bytes, "\n") do
                [line, _rest] -> Jason.decode(line)
                [line] when byte_size(line) < @max_header_bytes -> Jason.decode(line)
                _ -> {:error, :context_unavailable}
              end

            _ ->
              {:error, :context_unavailable}
          end
        after
          File.close(file)
        end

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp existing_cwd(cwd) when is_binary(cwd) and cwd != "" do
    if Path.type(cwd) == :absolute do
      case canonical_directory(cwd) do
        {:ok, _canonical} -> {:ok, cwd}
        _ -> {:error, :context_unavailable}
      end
    else
      {:error, :context_unavailable}
    end
  end

  defp existing_cwd(_), do: {:error, :context_unavailable}

  # Resolve trusted configured ancestors (including macOS /var and /tmp). All
  # descendants visited by the journal search itself must be real directories.
  defp canonical_directory(path), do: canonical_parts(Path.split(Path.expand(path)), "/", 40)

  defp canonical_parts([], path, _remaining), do: {:ok, path}
  defp canonical_parts(["/" | rest], path, remaining), do: canonical_parts(rest, path, remaining)

  defp canonical_parts([part | rest], parent, remaining) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        canonical_parts(rest, path, remaining)

      {:ok, %{type: :symlink}} when remaining > 0 ->
        with {:ok, target} <- File.read_link(path) do
          target = Path.expand(target, parent)
          canonical_parts(Path.split(Path.join([target | rest])), "/", remaining - 1)
        end

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
