defmodule LemonAgent.Workspace.KanbanAuthority do
  @moduledoc """
  Durable authority recorded on a kanban board (`meta["kanbanAuthority"]`).

  Every board created by a session, chat or operator records:

    * `principal` - the originating trusted identity (`agentId` and
      `sessionKey`, or an operator marker). Only that session, sessions an
      operator explicitly shared the board with (`sharedWith`) and operator
      surfaces may read, edit, start or stop it.
    * `policy` - the creator's effective tool policy, narrowed (never widened)
      by every later dispatch starter. An unrestricted trusted creator records
      an explicit full-access policy with `unrestricted: true`.
    * `root` - the canonical workspace boundary. Execution and worktree paths
      are re-resolved against it at every dispatch and recovery.
    * `publish` - an operator publication grant (`settings`, the resolved
      `destinations` — exact push URLs, PR repository and base — and
      `grantedBy: "operator"`) made through a revision-, settings- and
      destination-bound operator confirmation, or `nil`. Creator policy alone
      never grants it, and publication uses only the pinned destinations.
    * `inPlace` - an optional operator grant (`workspace` plus
      `grantedBy: "operator"`) that lets workers run directly in exactly that
      workspace instead of a controller-owned Git worktree.

  A board without a valid record is quarantined: it is never dispatched until
  an operator reauthorizes it. Only an operator path can widen authority.
  """

  alias LemonCore.ToolPolicy

  @version 1
  @key "kanbanAuthority"
  # Tools that start work in another session, agent, node, peer or schedule.
  # They do not carry the kanban authority, so workers and reviewers never get
  # them: kanban/goal/cron start durable work; agent_message and peer ask
  # existing sessions or remote peers that run under their own policy; agent,
  # task and nodes accept routing overrides to other sessions, agents or nodes.
  @delegation_tools ~w(kanban goal cron agent_message peer agent task nodes)
  @external_probe ~w(webfetch websearch)
  @max_shared 32

  def key, do: @key
  def delegation_tools, do: @delegation_tools

  @doc "Builds a session- or chat-originated authority."
  @spec new(map(), term(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def new(principal, policy, root, opts \\ []) do
    with {:ok, principal} <- principal(principal),
         {:ok, policy, unrestricted?} <- record_policy(policy),
         {:ok, root} <- canonical_directory(root),
         :ok <- publish_request(Keyword.get(opts, :publish), policy) do
      {:ok,
       %{
         "version" => @version,
         "principal" => principal,
         "grantedBy" => Keyword.get(opts, :granted_by, "session"),
         "unrestricted" => unrestricted?,
         "policy" => ToolPolicy.to_map(policy),
         "root" => root,
         "sharedWith" => [],
         "publish" => nil
       }}
    end
  end

  @doc "Operator reauthorization: full tool authority, no session principal, no publication."
  @spec operator(binary(), map() | nil) :: {:ok, map()} | {:error, term()}
  def operator(root, previous \\ nil) do
    with {:ok, root} <- canonical_directory(root) do
      {:ok,
       %{
         "version" => @version,
         "principal" => (valid_previous(previous) || %{})["principal"] || %{"operator" => true},
         "grantedBy" => "operator",
         "unrestricted" => true,
         "policy" => ToolPolicy.to_map(ToolPolicy.from_profile(:full_access)),
         "root" => root,
         "sharedWith" => (valid_previous(previous) || %{})["sharedWith"] || [],
         "publish" => nil
       }}
    end
  end

  defp valid_previous(previous) do
    case validate(previous) do
      {:ok, authority} -> authority
      _ -> nil
    end
  end

  @doc "Fetches the validated authority of a board; absent or malformed records fail closed."
  @spec fetch(map()) :: {:ok, map()} | {:error, :kanban_authority_missing}
  def fetch(%{meta: meta}) when is_map(meta), do: validate(meta[@key])
  def fetch(_board), do: {:error, :kanban_authority_missing}

  @spec validate(term()) :: {:ok, map()} | {:error, :kanban_authority_missing}
  def validate(
        %{
          "version" => @version,
          "principal" => principal,
          "grantedBy" => granted_by,
          "unrestricted" => unrestricted,
          "policy" => policy,
          "root" => root,
          "sharedWith" => shared,
          "publish" => publish
        } = authority
      )
      when granted_by in ["session", "channel", "operator"] and is_boolean(unrestricted) and
             is_binary(root) and is_list(shared) do
    with true <- valid_principal?(principal),
         {:ok, _} <- ToolPolicy.parse(policy),
         true <- Path.type(root) == :absolute,
         true <- Enum.all?(shared, &(is_binary(&1) and &1 != "")),
         true <- is_nil(publish) or is_map(publish) do
      {:ok, authority}
    else
      _ -> {:error, :kanban_authority_missing}
    end
  end

  def validate(_authority), do: {:error, :kanban_authority_missing}

  @doc "The recorded authority's tool policy."
  @spec policy(map()) :: ToolPolicy.t()
  def policy(%{"policy" => policy}), do: ToolPolicy.parse!(policy)

  @doc "Narrows an authority with a caller's policy; `nil` (unrestricted) leaves it unchanged."
  @spec restrict(map(), term()) :: {:ok, map()} | {:error, term()}
  def restrict(authority, nil), do: {:ok, authority}

  def restrict(authority, policy) do
    case ToolPolicy.restrict(authority["policy"], policy) do
      {:ok, restricted} ->
        {:ok,
         authority
         |> Map.put("policy", ToolPolicy.to_map(restricted))
         |> Map.put("unrestricted", false)}

      {:error, _} ->
        {:error, :invalid_tool_policy}
    end
  end

  @doc "Records an operator sharing grant for another trusted session."
  @spec share(map(), binary()) :: {:ok, map()} | {:error, term()}
  def share(authority, session_key) when is_binary(session_key) and session_key != "" do
    shared = Enum.uniq(authority["sharedWith"] ++ [session_key])

    if length(shared) <= @max_shared,
      do: {:ok, Map.put(authority, "sharedWith", shared)},
      else: {:error, :too_many_shares}
  end

  def share(_authority, _session_key), do: {:error, :invalid_session_key}

  @doc "Whether a trusted session principal may read and control the board."
  @spec permits?(map(), map()) :: boolean()
  def permits?(authority, %{session_key: session_key, agent_id: agent_id})
      when is_binary(session_key) and session_key != "" and is_binary(agent_id) do
    case authority["principal"] do
      %{"sessionKey" => ^session_key, "agentId" => ^agent_id} -> true
      _ -> session_key in authority["sharedWith"]
    end
  end

  def permits?(_authority, _principal), do: false

  @doc """
  Whether the controller may run `commands` (shell command strings) under the
  recorded policy: shell allowed, each command allowed by `allowed_commands`
  and not matched by `blocked_commands`, and no approval required. The
  controller cannot obtain approval, so any approval requirement refuses.
  """
  def commands_permitted?(policy, commands) do
    case ToolPolicy.parse(policy) do
      {:ok, policy} ->
        ToolPolicy.allowed?(policy, "bash") and
          Enum.all?(commands, fn command ->
            command_allowed?(policy, command) and
              not ToolPolicy.requires_approval?(policy, "bash", %{"command" => command}, :exec)
          end)

      {:error, _} ->
        false
    end
  end

  # Same matching as `LemonRouter.Policy.command_allowed?/2`.
  defp command_allowed?(policy, command) do
    not matches_any?(command, policy.blocked_commands) and
      (policy.allowed_commands == :all or matches_any?(command, policy.allowed_commands))
  end

  defp matches_any?(command, patterns),
    do: Enum.any?(patterns, &(String.starts_with?(command, &1) or String.contains?(command, &1)))

  @doc """
  Whether controller-owned local commits are authorized: workspace writes and
  the exact controller Git commands without approval.
  """
  def commit_permitted?(policy, commands),
    do:
      ToolPolicy.allowed?(policy, "write") and
        not ToolPolicy.requires_approval?(policy, "write", %{}, :write) and
        commands_permitted?(policy, commands)

  @doc """
  Whether the recorded policy permits publication commands: the exact push/PR
  commands, plus external network tools without approval. Publication also
  needs the operator grant (`granted_destinations/2`).
  """
  def publication_permitted?(policy, commands) do
    commands_permitted?(policy, commands) and
      Enum.all?(@external_probe, fn tool ->
        ToolPolicy.allowed?(policy, tool) and not ToolPolicy.requires_approval?(policy, tool)
      end)
  end

  @doc """
  The destinations an operator granted for exactly `settings`: `%{"push" =>
  [url, ...], "repository" => repo | nil, "base" => base | nil}`, resolved
  when the operator confirmed. Publication only ever uses these pinned values.
  """
  def granted_destinations(
        %{
          "publish" => %{
            "grantedBy" => "operator",
            "settings" => settings,
            "destinations" => %{"push" => [_ | _] = push} = destinations
          }
        },
        settings
      )
      when is_map(settings) do
    if Enum.all?(push, &is_binary/1), do: {:ok, destinations}, else: :error
  end

  def granted_destinations(_authority, _settings), do: :error

  @doc """
  Records an operator publication grant for exactly `settings` and the
  destinations resolved for the confirmation.
  """
  def grant_publication(authority, settings, %{"push" => [_ | _]} = destinations)
      when is_map(settings),
      do:
        {:ok,
         Map.put(authority, "publish", %{
           "settings" => settings,
           "destinations" => destinations,
           "grantedBy" => "operator"
         })}

  def grant_publication(_authority, _settings, _destinations),
    do: {:error, :publication_not_requested}

  @doc """
  Stable digest binding an operator confirmation to exact publish settings and
  the exact destinations (push URLs, PR repository and base) shown with them.
  """
  def publish_digest(settings, destinations) when is_map(settings) and is_map(destinations) do
    %{"settings" => settings, "destinations" => destinations}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def publish_digest(_settings, _destinations), do: nil

  @doc """
  Whether an operator allowed workers to run in place (no controller-owned
  worktree) in exactly `workspace`. In-place execution uses the caller's own
  directory, so it is refused without this grant.
  """
  def in_place_granted?(%{"inPlace" => %{"grantedBy" => "operator", "workspace" => ws}}, ws)
      when is_binary(ws),
      do: true

  def in_place_granted?(_authority, _workspace), do: false

  @doc "Records an operator in-place execution grant for exactly `workspace`."
  def grant_in_place(authority, workspace) when is_binary(workspace),
    do:
      {:ok, Map.put(authority, "inPlace", %{"grantedBy" => "operator", "workspace" => workspace})}

  def grant_in_place(_authority, _workspace), do: {:error, :invalid_workspace}

  @doc """
  Digest of a workspace path, so content-free operator previews can bind an
  in-place grant to the exact workspace without exposing the path.
  """
  def workspace_digest(workspace) when is_binary(workspace),
    do: :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)

  def workspace_digest(_workspace), do: nil

  @doc """
  The policy-matching text of a controller command built as
  `{executable, args}`: the executable and every argument, space-joined. The
  controller authorizes exactly the value it then runs.
  """
  def command_text({executable, args}) when is_binary(executable) and is_list(args),
    do: Enum.join([executable | args], " ")

  @doc """
  `{dev, inode}` identity of an existing directory, as passed to the session
  runner (`meta.cwd_identity`) to bind execution to the checked object.
  """
  @spec directory_identity(term()) :: {:ok, map()} | {:error, term()}
  def directory_identity(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok,
         %{"major" => stat.major_device, "minor" => stat.minor_device, "inode" => stat.inode}}

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, _} = error ->
        error
    end
  end

  def directory_identity(_path), do: {:error, :invalid_path}

  @doc """
  Resolves `path` to its canonical form: every component must exist and every
  symlink is followed. Any resolution error fails closed.
  """
  @spec canonical(term()) :: {:ok, binary()} | {:error, term()}
  def canonical(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute,
      do: resolve(Path.split(path), "/", 0),
      else: {:error, :relative_path}
  end

  def canonical(_path), do: {:error, :invalid_path}

  @doc "Canonical form of an existing directory."
  def canonical_directory(path) do
    with {:ok, real} <- canonical(path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(real) do
      {:ok, real}
    else
      {:ok, _stat} -> {:error, :not_a_directory}
      {:error, _} = error -> error
    end
  end

  @doc "Whether canonical `path` is `root` or inside it."
  def within?(path, root) when is_binary(path) and is_binary(root),
    do: path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  def within?(_path, _root), do: false

  @doc """
  Re-resolves a recorded canonical workspace and requires it to be unchanged and
  inside the authority root. A component replaced by a symlink changes it.
  """
  @spec check_workspace(map(), term()) :: {:ok, binary()} | {:error, atom()}
  def check_workspace(authority, workspace) do
    case canonical_directory(workspace) do
      {:ok, ^workspace} ->
        if within?(workspace, authority["root"]),
          do: {:ok, workspace},
          else: {:error, :workspace_outside_authorized_root}

      _ ->
        {:error, :workspace_changed}
    end
  end

  defp resolve(_parts, _resolved, hops) when hops > 40, do: {:error, :symlink_loop}
  defp resolve([], resolved, _hops), do: {:ok, resolved}
  defp resolve(["/" | rest], _resolved, hops), do: resolve(rest, "/", hops)
  defp resolve(["." | rest], resolved, hops), do: resolve(rest, resolved, hops)
  defp resolve([".." | rest], resolved, hops), do: resolve(rest, Path.dirname(resolved), hops)

  defp resolve([part | rest], resolved, hops) do
    candidate = Path.join(resolved, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target =
            if Path.type(target) == :absolute, do: target, else: Path.join(resolved, target)

          resolve(Path.split(target) ++ rest, "/", hops + 1)
        end

      {:ok, _stat} ->
        resolve(rest, candidate, hops)

      {:error, _} = error ->
        error
    end
  end

  defp principal(%{agent_id: agent_id, session_key: session_key})
       when is_binary(agent_id) and agent_id != "" and is_binary(session_key) and
              session_key != "",
       do: {:ok, %{"agentId" => agent_id, "sessionKey" => session_key}}

  defp principal(_), do: {:error, :session_identity_required}

  defp valid_principal?(%{"operator" => true}), do: true

  defp valid_principal?(%{"agentId" => agent_id, "sessionKey" => session_key}),
    do: is_binary(agent_id) and agent_id != "" and is_binary(session_key) and session_key != ""

  defp valid_principal?(_), do: false

  defp record_policy(nil), do: {:ok, ToolPolicy.from_profile(:full_access), true}

  defp record_policy(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, parsed} -> {:ok, parsed, false}
      {:error, _} -> {:error, :invalid_tool_policy}
    end
  end

  # A creator may only request publication when its own policy could push and
  # reach the network; the operator grant is still required to publish.
  defp publish_request(nil, _policy), do: :ok

  defp publish_request(publish, policy) when is_map(publish) do
    push = {"git", ["push", to_string(publish["remote"])]}

    pr =
      if publish["mode"] == "pull_request",
        do: [
          {"gh",
           [
             "pr",
             "create",
             "--repo",
             to_string(publish["repository"]),
             "--base",
             to_string(publish["base"])
           ]}
        ],
        else: []

    if publication_permitted?(policy, Enum.map([push | pr], &command_text/1)),
      do: :ok,
      else: {:error, :publication_not_permitted}
  end

  defp publish_request(_publish, _policy), do: {:error, :invalid_publish}
end
