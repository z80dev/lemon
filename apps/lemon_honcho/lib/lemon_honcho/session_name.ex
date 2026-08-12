defmodule LemonHoncho.SessionName do
  @moduledoc """
  Turns a Lemon run into the Honcho session id its memory belongs to.

  A Honcho session is the container everything else hangs off: messages are
  added to it, session context is read from it, and conclusions are scoped by
  it. Which runs share one is therefore a product decision, not an
  implementation detail, and `LemonHoncho.Config`'s `session_strategy` is how an
  operator makes it:

    * `:per_session` — one Honcho session per Lemon session. Nothing is shared;
      use it when runs are unrelated, or when a gateway hands each chat its own
      key and those chats must not see each other's memory.
    * `:per_directory` — one per working directory (the default). Every run in
      a project accumulates into the same memory, which is what makes the
      second conversation about a codebase better than the first.
    * `:per_repo` — one per git repository, so worktrees and subdirectories of
      the same project share memory instead of fragmenting it.
    * `:global` — one session for everything, named after the workspace.

  ## The two rules that are easy to get wrong

  Honcho session ids accept only `[A-Za-z0-9_-]`, so whatever a strategy
  produces is sanitized: runs of anything else collapse to a single `-` and
  leading/trailing `-` are trimmed. A path, a chat title with emoji, or a
  Matrix room key all survive this.

  Honcho also caps session ids at 100 characters, and gateway keys routinely
  exceed that — a Matrix `!room:server` plus a thread event id, or a Slack
  thread id behind a long workspace prefix. Truncating alone would be a
  correctness bug rather than a cosmetic one: two long keys that share a
  leading segment would land on the same id and their memories would merge. So
  an over-long id keeps a prefix and appends `-` plus the first eight hex
  characters of the SHA-256 of the **original, pre-sanitization** key. Hashing
  the original is what makes the suffix discriminate between keys that differ
  only after the truncation point, while two inputs that sanitize to the same
  string still collide on purpose — they are the same logical session.

  `resolve/2` always returns a usable id. If a strategy yields nothing (an
  empty cwd basename, a session key that is entirely punctuation) it falls back
  to the workspace name, and finally to a constant, because returning `""`
  would make every subsequent Honcho call fail in a way that is hard to trace
  back to here.
  """

  require Logger

  alias LemonHoncho.Config

  @max_length 100
  @hash_length 8
  @git_timeout_ms 5_000
  @last_resort "honcho"

  @doc """
  Resolves the Honcho session id for a run.

  ## Options

    * `:cwd` — the run's working directory. Defaults to the node's cwd.
    * `:session_key` — the gateway/channel session key, when the run has one.
    * `:session_id` — the Lemon session id.

  Under `:per_session` the Lemon session id is the identity, falling back to
  the session key when there is no session id; the other strategies ignore both
  and derive the id from the directory, the repository, or the workspace.

  ## Examples

      iex> config = %LemonHoncho.Config{session_strategy: :global, workspace: "lemon"}
      iex> LemonHoncho.SessionName.resolve(config)
      "lemon"

      iex> config = %LemonHoncho.Config{session_strategy: :per_session}
      iex> LemonHoncho.SessionName.resolve(config, session_id: "chat/42 ✨")
      "chat-42"
  """
  @spec resolve(Config.t(), keyword()) :: String.t()
  def resolve(%Config{} = config, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || current_directory()

    config
    |> base_name(opts, cwd)
    |> finalize(config)
  end

  defp base_name(%Config{session_strategy: :per_session}, opts, cwd) do
    Keyword.get(opts, :session_id) || Keyword.get(opts, :session_key) || Path.basename(cwd)
  end

  defp base_name(%Config{session_strategy: :per_repo}, _opts, cwd) do
    repo_name(cwd) || Path.basename(cwd)
  end

  defp base_name(%Config{session_strategy: :global} = config, _opts, _cwd), do: config.workspace

  defp base_name(%Config{}, _opts, cwd), do: Path.basename(cwd)

  # Sanitization can empty a name out entirely, and an empty session id is
  # rejected by every Honcho endpoint, so the fallbacks are part of the
  # contract rather than defensive padding.
  defp finalize(base, %Config{} = config) do
    case sanitize(base) do
      "" -> finalize_fallback(config)
      sanitized -> enforce_limit(sanitized, base)
    end
  end

  defp finalize_fallback(%Config{} = config) do
    case sanitize(config.workspace) do
      "" -> @last_resort
      sanitized -> enforce_limit(sanitized, config.workspace)
    end
  end

  defp sanitize(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_-]+/u, "-")
    |> String.trim("-")
  end

  defp sanitize(_value), do: ""

  defp enforce_limit(sanitized, original) do
    if String.length(sanitized) <= @max_length do
      sanitized
    else
      prefix =
        sanitized
        |> String.slice(0, @max_length - @hash_length - 1)
        |> String.trim_trailing("-")

      prefix <> "-" <> digest(original)
    end
  end

  defp digest(original) do
    :sha256
    |> :crypto.hash(to_string(original))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

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
  # the caller degrades to the directory name instead of blocking a turn.
  defp repo_name(cwd) do
    task = Task.async(fn -> git_toplevel(cwd) end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, name} ->
        name

      other ->
        Logger.debug("honcho: git repo lookup did not complete: #{inspect(other)}")
        nil
    end
  end

  defp git_toplevel(cwd) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> toplevel_basename(output)
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

  defp toplevel_basename(output) do
    case String.trim(output) do
      "" -> nil
      path -> Path.basename(path)
    end
  end
end
