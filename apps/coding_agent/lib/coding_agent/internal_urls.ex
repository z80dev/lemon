defmodule CodingAgent.InternalUrls do
  @moduledoc """
  Router for internal `notes://`, `skill://` and `artifact://` URLs.

  Skill keys and bundle-relative paths preserve case. A bare skill reference
  selects `SKILL.md`; path segments may percent-encode spaces and Unicode.
  Traversal, URL authority syntax, query/fragment suffixes, controls and nested
  percent encoding are rejected. Bundle files resolve through
  `LemonSkills.Bundle.resolve_file/2`, the resolver `read_skill` also uses:
  only `SKILL.md` and files under the bundle layout directories, no hidden
  segments, every segment lstat-checked (symlinks, FIFOs and devices refused)
  and a byte cap. The registered bundle root itself may be a symlink.

  Notes retain their session-scoped protocol semantics. Skill lookup uses the
  LemonSkills registry and the shared `LemonSkills.Status.loadable?/2` gate, so
  disabled, audit-blocked and unauthorized skills (no operator-side audit pass
  or approval for the exact live bundle) are refused. Artifact
  references retain the session scope supplied in `opts`. Unknown protocols
  return `{:error, :unknown_protocol}`.
  """

  alias CodingAgent.InternalUrls.NotesProtocol

  @type result :: {:ok, String.t()} | {:error, String.t() | atom()}

  @doc "Returns whether a URL uses a recognized internal protocol."
  @spec internal_url?(term()) :: boolean()
  def internal_url?("notes://" <> _), do: true

  def internal_url?(path) when is_binary(path) do
    String.valid?(path) and
      Regex.match?(~r/\A(?:skill|artifact|local|proc|issue|pr|history):/i, path)
  end

  def internal_url?(_path), do: false

  @doc """
  Resolves an internal URL using workspace and session options.

  `:cwd` supplies the working directory. Notes and artifacts also require
  `:session_id`; protocol-specific options are passed through unchanged.
  """
  @spec resolve(String.t(), keyword()) :: result()
  def resolve("notes://" <> _ = uri, opts) do
    NotesProtocol.resolve(uri, opts)
  end

  def resolve("local://" <> name, opts) do
    with true <- valid_segment?(name),
         {:ok, directory} <- CodingAgent.Artifacts.spill_dir(Keyword.fetch!(opts, :cwd), opts),
         {:ok, directory} <- physical_directory(directory, 40),
         root = Path.join(directory, "local"),
         :ok <- File.mkdir_p(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         path = Path.join(root, name),
         :ok <- local_file_type(path) do
      {:ok, path}
    else
      _ -> {:error, "Invalid or unavailable local URL"}
    end
  end

  def resolve("skill://" <> reference, opts) do
    cwd = Keyword.fetch!(opts, :cwd)

    with {:ok, key, segments} <- skill_reference(reference),
         {:ok, entry} <- available_skill(key, cwd) do
      resolve_segments(Path.expand(entry.path, cwd), segments)
    end
  end

  def resolve("artifact://" <> _ = uri, opts) do
    CodingAgent.Artifacts.resolve(uri, Keyword.fetch!(opts, :cwd), opts)
  end

  def resolve(uri, _opts) do
    if internal_url?(uri) do
      {:error, "Malformed internal URL"}
    else
      {:error, :unknown_protocol}
    end
  end

  defp skill_reference(reference) do
    with true <- String.valid?(reference),
         false <- Regex.match?(~r/[\p{Cc}\p{Cf}?#]/u, reference),
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, reference) do
      [key | segments] = String.split(reference, "/")
      key = URI.decode(key)
      segments = Enum.map(segments, &URI.decode/1)

      if valid_segment?(key) and not String.contains?(key, "@") and
           Enum.all?(segments, &valid_segment?/1) do
        {:ok, key, if(segments == [], do: ["SKILL.md"], else: segments)}
      else
        {:error, "Invalid skill URL path"}
      end
    else
      _ -> {:error, "Malformed skill URL"}
    end
  end

  defp valid_segment?(segment) do
    segment not in ["", ".", ".."] and String.valid?(segment) and
      not Regex.match?(~r/[\p{Cc}\p{Cf}\/\\:?#%]/u, segment)
  end

  defp available_skill(key, cwd) do
    case LemonSkills.get(key, cwd: cwd) do
      {:ok, entry} ->
        if LemonSkills.Status.loadable?(entry, cwd: cwd) do
          {:ok, entry}
        else
          {:error, "Skill is disabled, blocked or not authorized for its current content"}
        end

      :error ->
        {:error, "Skill not found"}
    end
  rescue
    _ -> {:error, "Skill registry unavailable"}
  catch
    :exit, _ -> {:error, "Skill registry unavailable"}
  end

  defp resolve_segments(root, segments) do
    case LemonSkills.Bundle.resolve_file(root, segments) do
      {:ok, path, _stat} ->
        {:ok, path}

      {:error, :symlink} ->
        {:error, "Symlinks beneath a skill bundle are not allowed"}

      {:error, :not_regular} ->
        {:error, "Skill URL must reference a regular file"}

      {:error, :enoent} ->
        {:error, "Skill file not found"}

      {:error, :too_large} ->
        {:error, "Skill file exceeds the size limit"}

      {:error, reason} when reason in [:hidden, :outside_layout, :invalid_path] ->
        {:error, "Skill URL path is outside the skill bundle layout"}

      {:error, _} ->
        {:error, "Skill file unavailable"}
    end
  end

  # Resolve only the trusted artifact base, not the caller-selected local file.
  # In particular macOS's temporary directory commonly starts with /var -> /private/var.
  defp physical_directory(_path, 0), do: {:error, :symlink_loop}

  defp physical_directory(path, remaining) do
    [root | segments] = Path.split(path)

    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, parent} ->
      candidate = Path.join(parent, segment)

      case File.read_link(candidate) do
        {:ok, target} ->
          case physical_directory(Path.expand(target, Path.dirname(candidate)), remaining - 1) do
            {:ok, resolved} -> {:cont, {:ok, resolved}}
            error -> {:halt, error}
          end

        {:error, reason} when reason in [:einval, :enoent] ->
          {:cont, {:ok, candidate}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp local_file_type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unsafe_path}
    end
  end
end
