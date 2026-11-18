defmodule LemonSkills.SkillRoot do
  @moduledoc false

  # Trusted-root containment for writes and removals of installed skill dirs.
  #
  # Every mutation of a skill root names a trusted *anchor* and requires every
  # path component strictly below the anchor, through the skill root itself, to
  # be a real directory (lstat, never followed):
  #
  #   * project roots (`<dir>/.lemon/skill`, `<dir>/.agents/skills`, ...) live in
  #     repository content, so their anchor is the project's
  #     `LemonCore.TrustedRoot` (the validated Git root's realpath, or the cwd's
  #     realpath outside a repository) — the same root the loaders read from. A
  #     project root outside that trusted root is never mutated;
  #   * the global root `<agent_dir>/skill` is anchored at the agent dir's real
  #     path, which must itself be a real directory (not a symlink) owned by the
  #     current user. A global root that is not under that trusted agent dir is
  #     never mutated.
  #
  # A skill directory that is itself a symlink is unlinked, never followed, when
  # removed.

  alias LemonCore.TrustedRoot
  alias LemonSkills.Config

  @type scope :: :global | {:project, String.t()}

  @doc """
  Returns `{:ok, root, anchor}` for the skill directory `path` when its parent
  is the mutable skill root of `scope`, else an error. Callers still check the
  root chain with `check_dir/3` before acting.
  """
  @spec locate(String.t(), scope()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def locate(path, scope) when is_binary(path) do
    root = path |> Path.expand() |> Path.dirname() |> physical(scope)

    case Enum.find(roots(scope), &(physical(Path.expand(&1), scope) == root)) do
      nil -> {:error, :outside_skill_roots}
      configured -> resolve_root(configured, scope)
    end
  end

  @doc """
  Resolves a configured skill root to `{:ok, root, anchor}`. The global root
  must be `<agent_dir>/skill`; its anchor is the agent dir validated by
  `trusted_dir/1`. Any other global root is never mutated.
  """
  @spec resolve_root(String.t(), scope()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def resolve_root(root, :global) do
    if Path.expand(root) == Path.expand(Config.global_skills_dir()) do
      with {:ok, anchor} <- trusted_dir(Config.agent_dir()) do
        {:ok, Path.join(anchor, Path.basename(root)), anchor}
      end
    else
      {:error, :untrusted_global_root}
    end
  end

  def resolve_root(root, {:project, cwd} = scope) do
    anchor = TrustedRoot.resolve(cwd)
    root = root |> Path.expand() |> physical(scope)

    if root != anchor and TrustedRoot.inside?(root, anchor),
      do: {:ok, root, anchor},
      else: {:error, :outside_trusted_root}
  end

  # Project roots are compared and anchored by physical path: a lexical path
  # under `cwd` is re-spelled under `cwd`'s realpath (configured roots from
  # `Config.project_skills_dirs/1` already are realpaths). Components below the
  # cwd are not resolved; `check_dir/3` refuses symlinks among them.
  defp physical(path, {:project, cwd}) do
    cwd = Path.expand(cwd)

    with true <- path == cwd or String.starts_with?(path, cwd <> "/"),
         {:ok, real_cwd} <- TrustedRoot.realpath(cwd) do
      if path == cwd, do: real_cwd, else: Path.join(real_cwd, Path.relative_to(path, cwd))
    else
      _ -> path
    end
  end

  defp physical(path, :global), do: path

  @doc """
  Validates an independently trusted directory and returns its expanded path.

  `dir` is created when missing. The configured path itself must not be a
  symlink, and its real path (every ancestor link resolved) must be a
  directory owned by the current user. Mutations below it are then checked
  component by component with `check_dir/3`.
  """
  @spec trusted_dir(String.t()) :: {:ok, String.t()} | {:error, term()}
  def trusted_dir(dir) when is_binary(dir) do
    dir = Path.expand(dir)

    with :ok <- mkdir_unless_link(dir),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, real} <- realpath(dir),
         {:ok, %File.Stat{type: :directory, uid: uid}} <- File.lstat(real),
         true <- uid == current_uid() do
      {:ok, dir}
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlinked_anchor, dir}}
      {:error, reason} -> {:error, {reason, dir}}
      _ -> {:error, {:untrusted_anchor, dir}}
    end
  end

  defp mkdir_unless_link(dir) do
    case File.lstat(dir) do
      {:ok, _} -> :ok
      {:error, :enoent} -> File.mkdir_p(dir)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks that every component strictly below `anchor`, through `path`, is a
  real directory. With `allow_missing: true` a missing tail is accepted (the
  caller creates it and checks again).
  """
  @spec check_dir(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def check_dir(anchor, path, opts \\ []) do
    anchor = Path.expand(anchor)
    path = Path.expand(path)
    allow_missing = Keyword.get(opts, :allow_missing, false)

    with {:ok, segments} <- below(anchor, path) do
      segments
      |> Enum.scan(anchor, &Path.join(&2, &1))
      |> Enum.reduce_while(:ok, fn component, :ok ->
        case File.lstat(component) do
          {:ok, %File.Stat{type: :directory}} ->
            {:cont, :ok}

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, {:symlinked_component, component}}}

          {:ok, _} ->
            {:halt, {:error, {:not_a_directory, component}}}

          {:error, :enoent} when allow_missing ->
            {:halt, :ok}

          {:error, reason} ->
            {:halt, {:error, {reason, component}}}
        end
      end)
    end
  end

  @doc """
  Creates `path` (a skill root or a directory inside one) under `anchor`,
  refusing symlinked components before and after creation.
  """
  @spec ensure_dir(String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_dir(anchor, path) do
    with :ok <- check_dir(anchor, path, allow_missing: true),
         :ok <- File.mkdir_p(path) do
      check_dir(anchor, path)
    end
  end

  @doc """
  Removes the skill directory `path` contained in a root under `anchor`. The
  parent chain must be real directories; a symlinked skill directory is
  unlinked, a real one removed recursively (`File.rm_rf/1` never follows
  links below it).
  """
  @spec remove(String.t(), String.t()) :: :ok | {:error, term()}
  def remove(anchor, path) do
    path = Path.expand(path)

    with :ok <- check_dir(anchor, Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          case File.rm_rf(path) do
            {:ok, _} -> :ok
            {:error, reason, _} -> {:error, reason}
          end

        {:ok, _} ->
          File.rm(path)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp below(anchor, path) do
    cond do
      path == anchor -> {:ok, []}
      String.starts_with?(path, anchor <> "/") -> {:ok, relative_parts(path, anchor)}
      true -> respelled_below(anchor, path)
    end
  end

  # A project anchor is a realpath (`LemonCore.TrustedRoot`), while callers may
  # spell a path through links above it (`/var` vs `/private/var`). Find the
  # ancestor of `path` that is a real directory (not a link) with the anchor's
  # name and resolves exactly to the anchor; everything below it stays
  # unresolved, so `check_dir/3` still refuses links inside the anchor.
  defp respelled_below(anchor, path) do
    path
    |> Path.split()
    |> prefixes()
    |> Enum.find(fn prefix ->
      Path.basename(prefix) == Path.basename(anchor) and
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(prefix)) and
        realpath(prefix) == {:ok, anchor}
    end)
    |> case do
      nil -> {:error, :outside_anchor}
      prefix when prefix == path -> {:ok, []}
      prefix -> {:ok, relative_parts(path, prefix)}
    end
  end

  defp prefixes(parts),
    do: for(n <- length(parts)..1//-1, do: parts |> Enum.take(n) |> Path.join())

  defp relative_parts(path, base),
    do: path |> String.replace_prefix(base <> "/", "") |> Path.split()

  defp roots(:global), do: Config.global_skills_dirs()

  # Unresolved candidates, so a symlinked `.lemon` or skill root is seen (and
  # refused by `check_dir/3`) rather than hidden behind its realpath.
  defp roots({:project, cwd}) when is_binary(cwd) do
    [
      Config.project_skills_dir(cwd)
      | Config.project_skills_candidates(cwd, TrustedRoot.resolve(cwd))
    ]
  end

  @doc false
  # Resolves every symlink in `path`, failing closed on loops or errors.
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
  def realpath(path) when is_binary(path),
    do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve(_segments, _acc, depth) when depth > 40, do: {:error, :eloop}
  defp resolve([], acc, _depth), do: {:ok, acc}
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([segment | rest], acc, depth) do
    next = Path.join(acc, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
          base = if Path.type(target) == :absolute, do: "/", else: acc
          resolve(Path.split(Path.expand(target, base)) ++ rest, "/", depth + 1)
        end

      {:ok, _} ->
        resolve(rest, next, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Publish the current user's uid once at boot (`LemonSkills.Application`).
  It never changes for the life of the node; idempotent.
  """
  @spec init_uid() :: :ok
  def init_uid do
    if :persistent_term.get({__MODULE__, :uid}, nil) == nil,
      do: :persistent_term.put({__MODULE__, :uid}, lookup_uid())

    :ok
  end

  # Outside a started application (scripts, isolated tests) the uid is looked
  # up on each call rather than cached.
  defp current_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil -> lookup_uid()
      uid -> uid
    end
  end

  defp lookup_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.to_integer(String.trim(out))
      _ -> :unknown
    end
  end
end
