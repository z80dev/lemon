defmodule CodingAgent.InternalUrls do
  @moduledoc """
  Router for internal `notes://`, `skill://` and `artifact://` URLs.

  Skill keys and bundle-relative paths preserve case. A bare skill reference
  selects `SKILL.md`; path segments may percent-encode spaces and Unicode.
  Traversal, URL authority syntax, query/fragment suffixes, controls and nested
  percent encoding are rejected. Symlinks below a skill bundle are rejected,
  while the registered bundle root itself may be a symlink.

  Notes retain their session-scoped protocol semantics. Skill lookup and
  activation use the existing LemonSkills registry and status checks. Artifact
  references retain the session scope supplied in `opts`. Unknown protocols
  return `{:error, :unknown_protocol}`.
  """

  alias CodingAgent.InternalUrls.NotesProtocol

  @type result :: {:ok, String.t()} | {:error, String.t() | atom()}

  @doc "Returns whether a URL uses a recognized internal protocol."
  @spec internal_url?(term()) :: boolean()
  def internal_url?("notes://" <> _), do: true

  def internal_url?(path) when is_binary(path) do
    String.valid?(path) and Regex.match?(~r/\A(?:skill|artifact|local|proc):/i, path)
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

  @doc "Parses a notes URL using the notes protocol handler."
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse("notes://" <> _ = uri) do
    NotesProtocol.parse_notes_url(uri)
  end

  def parse(_), do: {:error, :unknown_protocol}

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
        if LemonSkills.Status.check_entry(entry, cwd: cwd).ready do
          {:ok, entry}
        else
          {:error, "Skill is disabled or not ready"}
        end

      :error ->
        {:error, "Skill not found"}
    end
  rescue
    _ -> {:error, "Skill registry unavailable"}
  catch
    :exit, _ -> {:error, "Skill registry unavailable"}
  end

  defp resolve_segments(root, [segment | rest]) do
    path = Path.join(root, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "Symlinks beneath a skill bundle are not allowed"}

      {:ok, %File.Stat{type: :regular}} when rest == [] ->
        {:ok, path}

      {:ok, %File.Stat{type: :directory}} when rest != [] ->
        resolve_segments(path, rest)

      {:ok, _} ->
        {:error, "Skill URL must reference a regular file"}

      {:error, :enoent} ->
        {:error, "Skill file not found"}

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
