defmodule LemonCore.TrustedRoot do
  @moduledoc """
  The one trusted root for repository-data loaders: instruction files,
  `@path` imports, rule files, stream rules, file slash commands, subagent
  personas and project skills.

  `resolve/1` takes the session's trusted directory (`config_cwd`, never a Bot
  folder) and returns the realpath of its Git repository root, or of the
  directory itself when no repository contains it. Only a real repository
  counts (`git_root/1`): a `.git` directory holding `HEAD`, `objects/` and
  `refs/` (or a `commondir` file naming a directory that holds them, as linked
  worktrees do), or a `.git` file whose `gitdir:` target validates the same
  way. An empty `.git` file or directory never widens the root. The repository
  and its `.git` must also have the same owner as the directory, so another
  local user cannot widen the root by planting `/tmp/.git`. A same-user process
  able to forge a complete repository in a parent directory is outside this
  check; it depends on operator-state write protection.

  Ancestor walks stop at the root. Every candidate file or directory is
  resolved with `realpath/1` and must stay inside it: symlinks that leave the
  root are refused. Files must be regular and single-linked (`nlink == 1`), so
  a hard link cannot smuggle a host file in. `read/3` reads the resolved path,
  never the original spelling, and re-checks the file's identity after
  reading. A concurrent writer inside the root that swaps a path component for
  an outward link during the read itself is not prevented here; that needs a
  descriptor-bound open.
  """

  @max_gitfile_bytes 4_096

  @doc """
  Resolve every path component, failing closed on missing paths or symlink
  exhaustion (32 hops).
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, term()}
  def realpath(path) when is_binary(path) do
    resolve_links(Path.split(Path.absname(path)), "/", 0)
  end

  @doc "Realpath of `dir`'s validated Git root (same owner as `dir`), else of `dir`."
  @spec resolve(String.t()) :: String.t()
  def resolve(dir) when is_binary(dir) do
    dir = real_or_expanded(dir)

    with root when is_binary(root) <- git_root(dir),
         {:ok, %{uid: uid}} <- File.stat(dir),
         {:ok, %{uid: ^uid}} <- File.lstat(root),
         {:ok, %{uid: ^uid}} <- File.lstat(Path.join(root, ".git")) do
      real_or_expanded(root)
    else
      _ -> dir
    end
  end

  @doc """
  Nearest ancestor of `dir` (inclusive) whose `.git` is a real repository, or
  `nil`. Invalid markers (an empty `.git` file or directory) are skipped.
  """
  @spec git_root(String.t()) :: String.t() | nil
  def git_root(dir) when is_binary(dir), do: find_git_root(Path.expand(dir))
  def git_root(_), do: nil

  @doc """
  `dir` and its ancestors up to and including `root`, nearest first, as
  realpaths. Empty when `dir` does not resolve inside `root`.
  """
  @spec ancestors(String.t(), String.t()) :: [String.t()]
  def ancestors(dir, root) do
    with {:ok, real} <- realpath(dir),
         true <- inside?(real, root) do
      walk(real, root, [])
    else
      _ -> []
    end
  end

  @doc "Realpath of a regular, single-linked file inside `root`."
  @spec file(String.t(), String.t()) :: {:ok, String.t()} | :error
  def file(path, root) do
    with {:ok, real} <- realpath(path),
         true <- inside?(real, root),
         {:ok, %{type: :regular, links: 1}} <- File.lstat(real) do
      {:ok, real}
    else
      _ -> :error
    end
  end

  @doc "Realpath of a directory inside `root`."
  @spec dir(String.t(), String.t()) :: {:ok, String.t()} | :error
  def dir(path, root) do
    with {:ok, real} <- realpath(path),
         true <- inside?(real, root),
         {:ok, %{type: :directory}} <- File.lstat(real) do
      {:ok, real}
    else
      _ -> :error
    end
  end

  @doc """
  Read a confined file: `file/2`, then read the resolved path (at most
  `:max_bytes` when given) and confirm it is still the same single-linked
  regular file. Returns `{:ok, content, realpath}` or `:error`.
  """
  @spec read(String.t(), String.t(), keyword()) :: {:ok, binary(), String.t()} | :error
  def read(path, root, opts \\ []) do
    with {:ok, real} <- file(path, root),
         {:ok, before} <- File.lstat(real),
         {:ok, content} <- read_bounded(real, Keyword.get(opts, :max_bytes)),
         {:ok, after_stat} <- File.lstat(real),
         true <- same_file?(before, after_stat) do
      {:ok, content, real}
    else
      _ -> :error
    end
  end

  @doc "Whether the already-resolved `path` equals `root` or lies below it."
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(path, root), do: path == root or String.starts_with?(path, slash(root))

  defp same_file?(%File.Stat{} = a, %File.Stat{} = b) do
    a.type == :regular and b.type == :regular and b.links == 1 and a.inode == b.inode and
      a.major_device == b.major_device and a.minor_device == b.minor_device
  end

  defp read_bounded(path, nil), do: File.read(path)

  defp read_bounded(path, max) when is_integer(max) and max >= 0 do
    case File.open(path, [:read, :binary], &IO.binread(&1, max + 1)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, data} when is_binary(data) and byte_size(data) <= max -> {:ok, data}
      {:ok, data} when is_binary(data) -> {:error, :too_large}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} = error -> error
    end
  end

  defp find_git_root(dir) do
    cond do
      repository_marker?(Path.join(dir, ".git")) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_git_root(Path.dirname(dir))
    end
  end

  defp repository_marker?(marker) do
    case File.lstat(marker) do
      {:ok, %{type: :directory}} -> repository_dir?(marker)
      {:ok, %{type: :regular}} -> gitfile_repository?(marker)
      _ -> false
    end
  end

  defp gitfile_repository?(marker) do
    with {:ok, data} <- read_bounded(marker, @max_gitfile_bytes),
         [_, target] <- Regex.run(~r/\Agitdir:[ \t]*(\S[^\r\n]*?)[ \t]*\r?\n?\z/, data),
         gitdir = Path.expand(target, Path.dirname(marker)),
         {:ok, %{type: :directory}} <- File.stat(gitdir) do
      repository_dir?(gitdir)
    else
      _ -> false
    end
  end

  # A git directory has HEAD plus objects/ and refs/, either itself or in the
  # common directory a linked worktree's `commondir` file names.
  defp repository_dir?(gitdir) do
    regular?(Path.join(gitdir, "HEAD")) and
      (store_dir?(gitdir) or common_store?(gitdir))
  end

  defp common_store?(gitdir) do
    case read_bounded(Path.join(gitdir, "commondir"), @max_gitfile_bytes) do
      {:ok, data} ->
        common = data |> String.trim() |> Path.expand(gitdir)
        store_dir?(common)

      _ ->
        false
    end
  end

  defp store_dir?(dir),
    do: directory?(Path.join(dir, "objects")) and directory?(Path.join(dir, "refs"))

  defp regular?(path), do: match?({:ok, %{type: :regular}}, File.stat(path))
  defp directory?(path), do: match?({:ok, %{type: :directory}}, File.stat(path))

  defp walk(dir, root, acc) do
    parent = Path.dirname(dir)

    if dir == root or parent == dir,
      do: Enum.reverse([dir | acc]),
      else: walk(parent, root, [dir | acc])
  end

  defp slash("/"), do: "/"
  defp slash(root), do: root <> "/"

  defp real_or_expanded(dir) do
    case realpath(dir) do
      {:ok, real} -> real
      {:error, _} -> Path.expand(dir)
    end
  end

  defp resolve_links([], current, _hops), do: {:ok, current}
  defp resolve_links(["/" | rest], current, hops), do: resolve_links(rest, current, hops)
  defp resolve_links(["." | rest], current, hops), do: resolve_links(rest, current, hops)

  defp resolve_links([".." | rest], current, hops),
    do: resolve_links(rest, Path.dirname(current), hops)

  defp resolve_links([part | rest], current, hops) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when hops >= 32 ->
        {:error, :eloop}

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target = Path.absname(target, Path.dirname(candidate))
          resolve_links(Path.split(target) ++ rest, "/", hops + 1)
        end

      {:ok, %File.Stat{type: :directory}} ->
        resolve_links(rest, candidate, hops)

      {:ok, _stat} when rest == [] ->
        {:ok, candidate}

      {:ok, _stat} ->
        {:error, :enotdir}

      {:error, _} = error ->
        error
    end
  end
end
