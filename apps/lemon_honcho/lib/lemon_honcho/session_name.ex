defmodule LemonHoncho.SessionName do
  @moduledoc """
  Turns a Lemon run into the Honcho session id its memory belongs to.

  A Honcho session is the container everything else hangs off: messages are
  added to it, session context (including the summary injected into every
  prompt) is read from it, and conclusions are scoped by it. Which runs share
  one is therefore a privacy decision, not an implementation detail.

  ## Who may share a session

  `LemonHoncho.Config`'s `session_strategy` decides what a run's *place* is:

    * `:per_session` — the Lemon session id (or, without one, the session key).
    * `:per_directory` — the full, expanded working directory (the default).
    * `:per_repo` — the full path of the git repository root, so the
      subdirectories of one checkout share memory.
    * `:global` — the Honcho workspace.

  Every strategy is then partitioned by *who* the run is:

    * the complete **owner** (`:owner`, a `LemonHoncho.Owner`): agent profile,
      resolved human, and memory ownership, so two profiles, two people, or a
      private memory context and legacy memory never share a session (and so
      never share its injected summary);
    * for any session key that is not an agent's local main session (a channel
      conversation, a gateway key the parser does not recognise), the **full
      session key**, so a group chat and a private chat with the same person
      never share one.

  Honcho session ids accept only `[A-Za-z0-9_-]` and at most 100 characters.
  The id is a sanitized, bounded human-readable label (the directory or
  repository basename, the session id, or the workspace) followed by `-` and a
  128-bit length-prefixed SHA-256 digest of the `v2` namespace, the strategy,
  the full place and the identity above.

  The digest is not optional and not only for over-long names. A bare label is
  what made every channel and profile run share a session named `workspace`;
  and sanitization is lossy (`a:b` and `a/b` both read `a-b`), so the label
  alone can never decide identity. Only inputs that are byte-for-byte the same
  place and the same identity reach the same session.

  `resolve/2` always returns a usable id: an empty label falls back to the
  workspace name and finally to a constant, still followed by the digest.
  """

  require Logger

  alias LemonHoncho.Config

  @max_length 100
  @digest_hex 32
  @git_timeout_ms 5_000
  @last_resort "honcho"

  @doc """
  Resolves the Honcho session id for a run.

  ## Options

    * `:cwd` — the run's working directory. Defaults to the node's cwd.
    * `:session_key` — the gateway/channel session key, when the run has one.
      The whole key of a non-main session is part of the identity under every
      strategy.
    * `:session_id` — the Lemon session id (`:per_session` only).
    * `:owner` — the run's `LemonHoncho.Owner`.

  ## Examples

      iex> config = %LemonHoncho.Config{session_strategy: :global, workspace: "lemon"}
      iex> LemonHoncho.SessionName.resolve(config) =~ ~r/\\Alemon-[0-9a-f]{32}\\z/
      true

      iex> config = %LemonHoncho.Config{session_strategy: :per_session}
      iex> LemonHoncho.SessionName.resolve(config, session_id: "chat/42 ✨") =~ ~r/\\Achat-42-[0-9a-f]{32}\\z/
      true
  """
  @spec resolve(Config.t(), keyword()) :: String.t()
  def resolve(%Config{} = config, opts \\ []) do
    cwd = Path.expand(Keyword.get(opts, :cwd) || current_directory())
    {label, place} = place(config, opts, cwd)
    session_key = Keyword.get(opts, :session_key)

    identity = [
      "lemon-honcho-session",
      "v2",
      Atom.to_string(config.session_strategy),
      place,
      conversation(session_key),
      owner_digest(Keyword.get(opts, :owner))
    ]

    label(label, config) <> "-" <> LemonHoncho.Owner.digest(identity)
  end

  defp owner_digest(%LemonHoncho.Owner{digest: digest}), do: digest
  defp owner_digest(nil), do: ""

  defp place(%Config{session_strategy: :per_session}, opts, cwd) do
    case Keyword.get(opts, :session_id) || Keyword.get(opts, :session_key) do
      value when is_binary(value) and value != "" -> {value, value}
      _none -> {Path.basename(cwd), cwd}
    end
  end

  defp place(%Config{session_strategy: :per_repo}, _opts, cwd) do
    root = repo_root(cwd) || cwd
    {Path.basename(root), root}
  end

  defp place(%Config{session_strategy: :global} = config, _opts, _cwd) do
    {config.workspace, to_string(config.workspace)}
  end

  defp place(%Config{}, _opts, cwd), do: {Path.basename(cwd), cwd}

  # An agent's local main session (and its subagents) is the agent's own
  # conversation with its operator; every other key names a conversation that
  # must not share memory with any other.
  defp conversation(session_key) when is_binary(session_key) and session_key != "" do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :main} -> ""
      _other -> session_key
    end
  end

  defp conversation(_session_key), do: ""

  # The label is for humans reading Honcho's dashboard; identity is the digest.
  defp label(value, %Config{} = config) do
    [value, config.workspace, @last_resort]
    |> Enum.map(&sanitize/1)
    |> Enum.find(&(&1 != ""))
    |> String.slice(0, @max_length - @digest_hex - 1)
    |> String.trim_trailing("-")
    |> case do
      "" -> @last_resort
      label -> label
    end
  end

  defp sanitize(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp sanitize(_value), do: ""

  defp current_directory do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _reason} -> @last_resort
    end
  end

  # `git` is shelled out to rather than parsed out of `.git`, because worktrees
  # and submodules make the on-disk layout a poor proxy for "which repository
  # is this". It is also the one call here that can hang — a network-backed
  # filesystem, a credential prompt — so it runs in a task with a deadline and
  # the caller degrades to the directory instead of blocking a turn.
  defp repo_root(cwd) do
    task = Task.async(fn -> git_toplevel(cwd) end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, root} ->
        root

      other ->
        Logger.debug("honcho: git repo lookup did not complete: #{inspect(other)}")
        nil
    end
  end

  defp git_toplevel(cwd) do
    case LemonCore.NativeProcess.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} -> toplevel(output)
      {_output, _status} -> nil
    end
  rescue
    error ->
      Logger.debug("honcho: git repo lookup failed: #{inspect(error)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("honcho: git repo lookup exited: #{inspect(reason)}")
      nil
  end

  defp toplevel(output) do
    case String.trim(output) do
      "" -> nil
      path -> path
    end
  end
end
