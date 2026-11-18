defmodule LemonAgent.Workspace.GoalAuthority do
  @moduledoc """
  Durable caller authority recorded on a goal (`goal.authority`).

  Goal judge and continuation runs are submitted later by the automation
  manager, possibly after a restart, with no live caller. They therefore run
  only under the authority recorded when the goal was set:

    * `principal` - the trusted session identity (`agentId` and `sessionKey`)
      that set the goal, or `%{"operator" => true}` for operator surfaces
      (control plane, web). A session or chat principal must match the goal's
      own session key and agent.
    * `policy` - the setter's effective tool policy, narrowed (never widened)
      by every later starter. Operator authority records full access with
      `unrestricted: true`.
    * `root` - for session and chat authority, the canonical working
      directory of the setter. The goal target is that root or an existing
      directory inside it. Operator authority starts with no root; a starter
      narrows it to the starter's own root.

  The goal target is always an existing canonical directory (operator goals
  without one default to `LemonCore.Cwd.default_cwd/0`).

  A policy-bound starter (`narrow/3`) must be the goal's own session and agent,
  and the goal target must lie inside the starter's canonical root; the
  recorded policy is intersected with the starter's and the root narrowed to
  the stricter of the two.

  `run_scope/2` derives every judge and continuation run from the record: the
  run policy is intersected with it and always blocks the delegation tools
  (`delegation_tools/0`), which start or route work elsewhere without carrying
  this authority; the target is re-resolved inside the root and bound to its
  directory identity (`meta.cwd_identity`), which the session runner verifies
  at session start and before every tool call.

  A goal without a valid record (including goals persisted before authority
  existed) is quarantined: it never starts, and re-setting it from a trusted
  surface records fresh authority.
  """

  alias LemonAgent.Workspace.KanbanAuthority
  alias LemonCore.ToolPolicy

  @version 1

  @doc """
  Tools goal runs never get: scheduling (`cron`), kanban dispatch, goals, and
  every tool that delegates to another session, agent, node or peer
  (`KanbanAuthority.delegation_tools/0`). None of them carries goal authority.
  """
  @spec delegation_tools() :: [String.t()]
  def delegation_tools, do: KanbanAuthority.delegation_tools()

  @doc "Builds session (`granted_by: \"session\"`) or chat (`\"channel\"`) authority."
  @spec new(map(), term(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def new(principal, policy, root, opts \\ []) do
    granted_by = Keyword.get(opts, :granted_by, "session")

    with true <- granted_by in ["session", "channel"] || {:error, :invalid_granted_by},
         {:ok, principal} <- principal(principal),
         {:ok, policy, unrestricted?} <- record_policy(policy),
         {:ok, root} <- KanbanAuthority.canonical_directory(root) do
      {:ok,
       %{
         "version" => @version,
         "principal" => principal,
         "grantedBy" => granted_by,
         "unrestricted" => unrestricted?,
         "policy" => ToolPolicy.to_map(policy),
         "root" => root
       }}
    end
  end

  @doc "Operator authority: full tool authority, no session principal, no workspace root."
  @spec operator() :: map()
  def operator do
    %{
      "version" => @version,
      "principal" => %{"operator" => true},
      "grantedBy" => "operator",
      "unrestricted" => true,
      "policy" => ToolPolicy.to_map(ToolPolicy.from_profile(:full_access)),
      "root" => nil
    }
  end

  @doc "The validated authority of a goal; absent or malformed records fail closed."
  @spec fetch(map()) :: {:ok, map()} | {:error, :goal_authority_missing}
  def fetch(%{authority: authority}), do: validate(authority)
  def fetch(_goal), do: {:error, :goal_authority_missing}

  @spec validate(term()) :: {:ok, map()} | {:error, :goal_authority_missing}
  def validate(
        %{
          "version" => @version,
          "principal" => principal,
          "grantedBy" => granted_by,
          "unrestricted" => unrestricted,
          "policy" => policy,
          "root" => root
        } = authority
      )
      when is_boolean(unrestricted) do
    with true <- valid_grant?(granted_by, principal, root),
         {:ok, _} <- ToolPolicy.parse(policy) do
      {:ok, authority}
    else
      _ -> {:error, :goal_authority_missing}
    end
  end

  def validate(_authority), do: {:error, :goal_authority_missing}

  @doc """
  Whether `authority` may be recorded on, and run, the goal of `session_key`
  for `agent_id`. Operator authority covers any goal.
  """
  @spec permits?(map(), term(), term()) :: boolean()
  def permits?(%{"principal" => %{"operator" => true}, "grantedBy" => "operator"}, _key, _agent),
    do: true

  def permits?(%{"principal" => %{"sessionKey" => key, "agentId" => agent}}, key, agent),
    do: true

  def permits?(_authority, _session_key, _agent_id), do: false

  @doc """
  Narrows `authority` for a trusted starter (a `new/4` record: the starter's
  session, agent, policy and canonical root). The starter must be the goal's
  own session and agent, and the goal target must lie inside its root. The
  policy is intersected and the root becomes the stricter of the two.
  """
  @spec narrow(map(), map(), term()) :: {:ok, map()} | {:error, term()}
  def narrow(authority, goal, starter) do
    with {:ok, %{"principal" => principal} = starter} <- validate(starter),
         true <- starter_bound?(principal, goal) || {:error, :starter_not_permitted},
         {:ok, root} <- narrow_root(authority["root"], starter["root"], goal[:cwd]),
         {:ok, policy} <- restrict_policy(authority["policy"], starter["policy"]) do
      {:ok,
       authority
       |> Map.put("policy", ToolPolicy.to_map(policy))
       |> Map.put("unrestricted", false)
       |> Map.put("root", root)}
    end
  end

  defp starter_bound?(%{"sessionKey" => key, "agentId" => agent}, goal),
    do: key == goal[:session_key] and agent == (goal[:agent_id] || "default")

  defp starter_bound?(_principal, _goal), do: false

  defp narrow_root(recorded, starter_root, target) when is_binary(target) do
    with {:ok, ^target} <- KanbanAuthority.canonical_directory(target),
         true <- KanbanAuthority.within?(target, starter_root) do
      cond do
        is_nil(recorded) -> {:ok, starter_root}
        KanbanAuthority.within?(starter_root, recorded) -> {:ok, starter_root}
        KanbanAuthority.within?(recorded, starter_root) -> {:ok, recorded}
        true -> {:error, :workspace_outside_root}
      end
    else
      _ -> {:error, :workspace_outside_root}
    end
  end

  defp narrow_root(_recorded, _starter_root, _target), do: {:error, :workspace_outside_root}

  defp restrict_policy(recorded, starter) do
    case ToolPolicy.restrict(recorded, starter) do
      {:ok, policy} -> {:ok, policy}
      {:error, _} -> {:error, :invalid_tool_policy}
    end
  end

  @doc """
  Resolves the goal target for `authority`: `cwd` (relative paths resolve
  against the root) or the root itself, canonical and inside the root.
  Operator authority without a root accepts any existing directory and
  defaults to `LemonCore.Cwd.default_cwd/0`.
  """
  @spec target(map(), term()) :: {:ok, binary()} | {:error, :workspace_outside_root}
  def target(%{"root" => nil}, cwd) do
    path =
      case cwd do
        value when is_binary(value) and value != "" -> Path.expand(value)
        _ -> LemonCore.Cwd.default_cwd()
      end

    case KanbanAuthority.canonical_directory(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _} -> {:error, :workspace_outside_root}
    end
  end

  def target(%{"root" => root}, cwd) do
    path =
      case cwd do
        value when is_binary(value) and value != "" -> Path.expand(value, root)
        _ -> root
      end

    with {:ok, canonical} <- KanbanAuthority.canonical_directory(path),
         true <- KanbanAuthority.within?(canonical, root) do
      {:ok, canonical}
    else
      _ -> {:error, :workspace_outside_root}
    end
  end

  @doc """
  The run scope of a goal's judge or continuation: `base_policy` with the
  delegation tools blocked, confined to the recorded policy; the goal target
  re-resolved against the root (a component replaced by a symlink, or a target
  now outside the root, fails); and the target's directory identity, which
  the run carries as `meta.cwd_identity`.
  """
  @spec run_scope(map(), map()) ::
          {:ok, %{tool_policy: map(), cwd: binary(), cwd_identity: map()}}
          | {:error, :goal_authority_missing | :workspace_changed}
  def run_scope(goal, base_policy) when is_map(goal) and is_map(base_policy) do
    with {:ok, authority} <- fetch(goal),
         true <-
           permits?(authority, goal[:session_key], goal[:agent_id]) ||
             {:error, :goal_authority_missing},
         {:ok, cwd, identity} <- bind_cwd(authority, goal[:cwd]) do
      {:ok,
       %{
         tool_policy:
           base_policy
           |> ToolPolicy.intersect(%{blocked_tools: delegation_tools()})
           |> ToolPolicy.intersect(authority["policy"]),
         cwd: cwd,
         cwd_identity: identity
       }}
    end
  end

  defp bind_cwd(%{"root" => root}, cwd) when is_binary(cwd) do
    with {:ok, ^cwd} <- KanbanAuthority.canonical_directory(cwd),
         true <- is_nil(root) or KanbanAuthority.within?(cwd, root),
         {:ok, identity} <- KanbanAuthority.directory_identity(cwd) do
      {:ok, cwd, identity}
    else
      _ -> {:error, :workspace_changed}
    end
  end

  defp bind_cwd(_authority, _cwd), do: {:error, :workspace_changed}

  defp valid_grant?("operator", %{"operator" => true}, root), do: valid_root?(root, true)

  defp valid_grant?(granted_by, %{"agentId" => agent_id, "sessionKey" => session_key}, root)
       when granted_by in ["session", "channel"] do
    is_binary(agent_id) and agent_id != "" and is_binary(session_key) and session_key != "" and
      valid_root?(root, false)
  end

  defp valid_grant?(_granted_by, _principal, _root), do: false

  defp valid_root?(nil, nil_allowed?), do: nil_allowed?
  defp valid_root?(root, _nil_allowed?) when is_binary(root), do: Path.type(root) == :absolute
  defp valid_root?(_root, _nil_allowed?), do: false

  defp principal(%{agent_id: agent_id, session_key: session_key})
       when is_binary(agent_id) and agent_id != "" and is_binary(session_key) and
              session_key != "",
       do: {:ok, %{"agentId" => agent_id, "sessionKey" => session_key}}

  defp principal(_), do: {:error, :session_identity_required}

  defp record_policy(nil), do: {:ok, ToolPolicy.from_profile(:full_access), true}

  defp record_policy(policy) do
    case ToolPolicy.parse(policy) do
      {:ok, parsed} -> {:ok, parsed, false}
      {:error, _} -> {:error, :invalid_tool_policy}
    end
  end
end
