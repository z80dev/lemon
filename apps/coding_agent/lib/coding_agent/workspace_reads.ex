defmodule CodingAgent.WorkspaceReads do
  @moduledoc """
  Safety predicate and egress fence for unreviewed reads inside a Bot folder.

  Under `workspace_read_exempt: true`, native `read`, `ls`, and `grep` calls skip
  approval when:
  1. The tool policy specifies `workspace_read_exempt == true`.
  2. The session carries a trusted worker-derived `bot_folder_root` matching
     the canonical `ProfileStore.paths(profile_id)["files"]` root.
  3. Every target path resolves inside the folder after `realpath` symlink
     resolution, with internal URLs rejected. For `read`, the file must be regular
     with `nlink == 1` (blocking hard-link smuggling).
  4. `grep` qualifies only when ripgrep (`rg`) is available without symlink-following.
     `find` never qualifies.

  Once an exempt read occurs in a session, the egress fence is activated:
  - `webfetch` and `websearch` require approval for the rest of that session.
  - The fence is persisted in the session journal as `workspace_read_fence` and
    mirrored in an ETS table for lock-free checks inside tool tasks.
  - Subagent / task children spawned from a fenced session inherit the fence.
  - Session restore reseeds the fence from `workspace_read_fence`.
  """

  use GenServer

  alias CodingAgent.Tools.PathHelpers

  @table :coding_agent_workspace_read_fence
  @selector_token ~r/\A(?:img|conflicts|raw|\d+(?:-\d*|\+\d+)?(?:,\d+(?:-\d*|\+\d+)?)*|-\d+)\z/
  @fence_entry "workspace_read_fence"

  # Public API
  # ============================================================================

  @doc "Start the WorkspaceReads ETS supervisor worker."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Custom session-journal entry type that persists the egress fence."
  @spec fence_entry_type() :: String.t()
  def fence_entry_type, do: @fence_entry

  @doc """
  Check whether a session is fenced for web egress.

  A context seeded from the restored or inherited journal entry carries
  `:workspace_read_fenced`, so the gate survives even when the ETS mirror is
  unavailable. Every registered session records its state at initialization, so
  a live registered session with no row (the mirror was lost when its owner
  restarted) is treated as fenced rather than as unreviewed egress.
  """
  @spec fenced?(term()) :: boolean()
  def fenced?(session_or_context) do
    seeded_fence?(session_or_context) or
      case extract_session_id(session_or_context) do
        session_id when is_binary(session_id) and session_id != "" ->
          case mirror_lookup(session_id) do
            {:ok, fenced?} -> fenced?
            :unknown -> live_session?(session_id)
          end

        _ ->
          false
      end
  end

  defp seeded_fence?(ctx) when is_map(ctx) or is_list(ctx),
    do: get_ctx(ctx, :workspace_read_fenced) == true

  defp seeded_fence?(_), do: false

  defp mirror_lookup(session_id) do
    if :ets.whereis(@table) == :undefined do
      :unknown
    else
      case :ets.lookup(@table, session_id) do
        [{^session_id, fenced?}] -> {:ok, fenced? == true}
        [] -> :unknown
      end
    end
  end

  defp live_session?(session_id) do
    case Registry.lookup(CodingAgent.SessionRegistry, session_id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Record a session's fence state at initialization.

  The explicit row is what lets `fenced?/1` tell "known unfenced" apart from
  "mirror lost", so a restarted ETS owner cannot silently reopen web egress.
  """
  @spec register_session(String.t(), boolean()) :: :ok | {:error, :fence_unavailable}
  def register_session(session_id, fenced?)
      when is_binary(session_id) and session_id != "" and is_boolean(fenced?) do
    if :ets.whereis(@table) == :undefined do
      {:error, :fence_unavailable}
    else
      :ets.insert(@table, {session_id, fenced?})
      :ok
    end
  end

  def register_session(_session_id, _fenced?), do: {:error, :fence_unavailable}

  @doc "Mirror an already-durable fence in the ETS table for a session id."
  @spec set_fenced(String.t()) :: :ok | {:error, :fence_unavailable}
  def set_fenced(session_id) when is_binary(session_id) and session_id != "" do
    register_session(session_id, true)
  end

  def set_fenced(_), do: {:error, :fence_unavailable}

  @doc """
  Activate the egress fence for a session, failing closed.

  The fence is durable before it is reported: the owning Session process
  appends and persists the `workspace_read_fence` journal entry and mirrors it
  in ETS. A missing table, an unknown or unreachable session, or a failed
  journal write returns an error, and the caller must then review the read
  rather than let unreviewed data through an unfenced session.
  """
  @spec fence!(term()) :: :ok | {:error, atom()}
  def fence!(session_or_context) do
    cond do
      :ets.whereis(@table) == :undefined ->
        {:error, :fence_unavailable}

      is_pid(session_or_context) ->
        persist_fence(session_or_context)

      is_binary(session_or_context) and session_or_context != "" ->
        case Registry.lookup(CodingAgent.SessionRegistry, session_or_context) do
          [{pid, _}] when is_pid(pid) -> persist_fence(pid)
          _ -> {:error, :session_unavailable}
        end

      true ->
        case extract_session_id(session_or_context) do
          session_id when is_binary(session_id) and session_id != "" -> fence!(session_id)
          _ -> {:error, :session_unavailable}
        end
    end
  end

  # The journal is written by the owning Session process; a tool task calls in.
  # A call from inside that process cannot be answered, so it fails closed.
  defp persist_fence(pid) when is_pid(pid) do
    if pid == self() do
      {:error, :session_unavailable}
    else
      try do
        case CodingAgent.Session.record_workspace_read_fence(pid) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          _ -> {:error, :fence_unavailable}
        end
      catch
        :exit, _ -> {:error, :session_unavailable}
      end
    end
  end

  @doc "Check if the tool policy permits folder read exemptions."
  @spec policy_exempt?(term()) :: boolean()
  def policy_exempt?(policy) when is_map(policy) do
    Map.get(policy, :workspace_read_exempt) == true or
      Map.get(policy, "workspace_read_exempt") == true
  end

  def policy_exempt?(_), do: false

  @doc """
  Determine whether a tool call qualifies for approval exemption.

  Requires policy `workspace_read_exempt: true`, trusted worker-derived
  `bot_folder_root` matching `ProfileStore.paths(profile_id)["files"]`,
  tool in `[\"read\", \"ls\", \"grep\"]`, and target paths strictly inside
  the folder after symlink resolution.
  """
  @spec exempt?(term(), String.t() | LemonAgent.Types.AgentTool.t(), map(), term()) :: boolean()
  def exempt?(policy, %LemonAgent.Types.AgentTool{name: name}, params, ctx) do
    exempt?(policy, name, params, ctx)
  end

  def exempt?(policy, tool_name, params, ctx) when is_binary(tool_name) do
    with true <- policy_exempt?(policy),
         true <- tool_name in ["read", "ls", "grep"],
         {:ok, canonical_root} <- validate_bot_folder_root(ctx) do
      check_tool_exemption(tool_name, params, canonical_root, ctx)
    else
      _ -> false
    end
  end

  def exempt?(_policy, _tool, _params, _ctx), do: false

  @doc "Resolve symlinks in every component of an absolute path."
  @spec realpath(String.t()) :: String.t()
  def realpath(path) when is_binary(path) do
    path
    |> Path.expand()
    |> resolve_links(0)
    |> elem(0)
  end

  # Server
  # ============================================================================

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    {:ok, %{}}
  end

  # Internal Helpers
  # ============================================================================

  defp extract_session_id(id) when is_binary(id), do: id

  # Lock-free: the registry key is the session id, so a busy session is never
  # called just to learn its own identity.
  defp extract_session_id(pid) when is_pid(pid) do
    case Registry.keys(CodingAgent.SessionRegistry, pid) do
      [id | _] when is_binary(id) -> id
      _ -> nil
    end
  end

  defp extract_session_id(%CodingAgent.SessionManager.Session{header: %{id: id}}), do: id

  defp extract_session_id(%{session_manager: %{header: %{id: id}}}) when is_binary(id), do: id

  defp extract_session_id(map) when is_map(map),
    do: Map.get(map, :session_id) || Map.get(map, "session_id")

  defp extract_session_id(kw) when is_list(kw), do: Keyword.get(kw, :session_id)

  defp extract_session_id(_), do: nil

  # The root is only trusted when the worker-derived private root, the bound
  # `ExecutionContext` workspace scope and the folder `ProfileStore` derives
  # from the validated id are the same directory after symlink resolution.
  defp validate_bot_folder_root(ctx) do
    bot_folder_root = get_ctx(ctx, :bot_folder_root)
    profile_id = get_ctx(ctx, :native_source_profile_id)
    scope_root = workspace_scope_root(ctx)

    with true <- is_binary(bot_folder_root) and bot_folder_root != "",
         true <- is_binary(profile_id) and profile_id != "",
         true <- is_binary(scope_root) and scope_root != "",
         {:ok, %{"files" => expected}} <- LemonCore.ProfileStore.paths(profile_id),
         canonical_root <- realpath(bot_folder_root),
         true <- canonical_root == realpath(expected),
         true <- canonical_root == realpath(scope_root),
         true <- File.dir?(canonical_root) do
      {:ok, canonical_root}
    else
      _ -> :error
    end
  end

  defp workspace_scope_root(ctx) do
    case get_ctx(ctx, :workspace_scope_root) do
      root when is_binary(root) ->
        root

      _ ->
        case get_ctx(ctx, :execution_context) do
          %{workspace_scope: %{root: root}} when is_binary(root) -> root
          _ -> nil
        end
    end
  end

  defp get_ctx(ctx, key) when is_map(ctx) do
    Map.get(ctx, key) || Map.get(ctx, to_string(key))
  end

  defp get_ctx(ctx, key) when is_list(ctx) do
    Keyword.get(ctx, key) || Keyword.get(ctx, to_string(key))
  end

  defp get_ctx(_ctx, _key), do: nil

  defp get_param(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, to_string(key))
  end

  defp get_param(_params, _key), do: nil

  defp check_tool_exemption("read", params, root, ctx) do
    path = get_param(params, :path)

    is_binary(path) and path != "" and not internal_url?(path) and
      read_target_exempt?(path, cwd(ctx, root), root)
  end

  defp check_tool_exemption("ls", params, root, ctx) do
    path = get_param(params, :path) || "."

    is_binary(path) and path != "" and not internal_url?(path) and
      listed_target_exempt?(path, cwd(ctx, root), root)
  end

  # The Elixir fallback follows symlinks, so `grep` qualifies only on the `rg`
  # path, which is invoked without `-L`.
  defp check_tool_exemption("grep", params, root, ctx) do
    path = get_param(params, :path) || "."

    with true <- CodingAgent.Tools.Grep.ripgrep_available?(),
         true <- is_binary(path) and path != "" do
      cwd = cwd(ctx, root)

      roots =
        path
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      roots != [] and
        Enum.all?(roots, fn entry ->
          not internal_url?(entry) and listed_target_exempt?(entry, cwd, root)
        end)
    else
      _ -> false
    end
  end

  defp cwd(ctx, root), do: get_ctx(ctx, :cwd) || root

  # A hard link gives a second name to bytes that may live outside the folder,
  # so only single-linked regular files qualify for an unreviewed read.
  defp read_target_exempt?(path, cwd, root) do
    target = resolve_real(strip_path_selector(path, cwd), cwd)

    strictly_inside?(target, root) and
      match?({:ok, %File.Stat{type: :regular, links: 1}}, File.stat(target))
  end

  defp listed_target_exempt?(path, cwd, root) do
    target = resolve_real(path, cwd)
    File.exists?(target) and inside_or_equal?(target, root)
  end

  defp resolve_real(path, cwd), do: path |> PathHelpers.resolve_path(cwd) |> realpath()

  defp strictly_inside?(target, root) do
    root = String.trim_trailing(root, "/")
    String.starts_with?(target, root <> "/")
  end

  defp inside_or_equal?(target, root) do
    root = String.trim_trailing(root, "/")
    target == root or String.starts_with?(target, root <> "/")
  end

  defp internal_url?(path) when is_binary(path) do
    String.contains?(path, "://")
  end

  defp internal_url?(_), do: true

  # `read` applies a trailing `:selector` only when the literal path is missing,
  # so the exemption predicate must resolve the same base file.
  defp strip_path_selector(path, cwd) do
    if File.exists?(PathHelpers.resolve_path(path, cwd)) do
      path
    else
      path
      |> String.split(":")
      |> Enum.reverse()
      |> drop_selector_tokens(0)
      |> Enum.reverse()
      |> Enum.join(":")
    end
  end

  defp drop_selector_tokens([token | rest], dropped) when rest != [] and dropped < 2 do
    if Regex.match?(@selector_token, token),
      do: drop_selector_tokens(rest, dropped + 1),
      else: [token | rest]
  end

  defp drop_selector_tokens(segments, _dropped), do: segments

  defp resolve_links(path, hops) do
    path
    |> Path.split()
    |> Enum.reduce({"/", hops}, fn
      "/", acc ->
        acc

      part, {current, hops} ->
        candidate = Path.join(current, part)

        case File.read_link(candidate) do
          {:ok, target} when hops < 32 ->
            target
            |> Path.expand(Path.dirname(candidate))
            |> resolve_links(hops + 1)

          _ ->
            {candidate, hops}
        end
    end)
  end
end
