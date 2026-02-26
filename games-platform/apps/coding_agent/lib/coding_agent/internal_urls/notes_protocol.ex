defmodule CodingAgent.InternalUrls.NotesProtocol do
  @moduledoc """
  Handler for the `notes://` protocol.

  Provides session-scoped artifact storage for the coding agent.
  The `notes://` protocol replaced the older `plan://` protocol and
  supports reading, writing, listing, and renaming artifacts within
  a session's notes directory.

  ## URL Format

      notes://artifact-name.md
      notes://subdir/artifact.md

  ## Storage Layout

      ~/.lemon/agent/sessions/<encoded-cwd>/notes/<session_id>/
      ├── plan.md
      ├── approved-plan.md
      └── subdir/
          └── diagram.md

  ## Path Traversal Protection

  All resolved paths are validated to ensure they remain within the
  session's notes directory. Paths containing `..` or absolute components
  are rejected.
  """

  alias CodingAgent.Config

  @scheme "notes"
  @notes_dir "notes"

  @type parsed_url :: %{
          scheme: String.t(),
          path: String.t()
        }

  # ============================================================================
  # URL Parsing
  # ============================================================================

  @doc """
  Parse a `notes://` URL into its components.

  ## Parameters

    * `url` - The notes:// URL string

  ## Returns

    * `{:ok, parsed}` - Successfully parsed URL with scheme and path
    * `{:error, reason}` - Parse failure

  ## Examples

      iex> NotesProtocol.parse_notes_url("notes://plan.md")
      {:ok, %{scheme: "notes", path: "plan.md"}}

      iex> NotesProtocol.parse_notes_url("notes://subdir/artifact.md")
      {:ok, %{scheme: "notes", path: "subdir/artifact.md"}}

      iex> NotesProtocol.parse_notes_url("http://example.com")
      {:error, :invalid_scheme}
  """
  @spec parse_notes_url(String.t()) :: {:ok, parsed_url()} | {:error, atom()}
  def parse_notes_url(url) when is_binary(url) do
    case String.split(url, "://", parts: 2) do
      [@scheme, ""] ->
        {:error, :empty_path}

      [@scheme, path] ->
        normalized = path |> String.trim_leading("/") |> String.trim_trailing("/")

        if normalized == "" do
          {:error, :empty_path}
        else
          {:ok, %{scheme: @scheme, path: normalized}}
        end

      [_, _] ->
        {:error, :invalid_scheme}

      _ ->
        {:error, :invalid_url}
    end
  end

  def parse_notes_url(_), do: {:error, :invalid_url}

  # ============================================================================
  # Path Resolution
  # ============================================================================

  @doc """
  Resolve a notes:// URL to a filesystem path.

  Validates the path to prevent directory traversal attacks and ensures
  the resolved path stays within the session's notes directory.

  If the file does not exist in the current session, fallback session IDs
  are checked in order.

  ## Parameters

    * `url` - The notes:// URL string
    * `opts` - Resolution options with session context

  ## Options

    * `:session_id` - The current session ID (required)
    * `:cwd` - The current working directory (required)
    * `:fallback_session_ids` - Additional session IDs to search (optional)

  ## Returns

    * `{:ok, path}` - The resolved filesystem path
    * `{:error, reason}` - Resolution failure
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def resolve(url, opts) do
    with {:ok, parsed} <- parse_notes_url(url),
         :ok <- validate_path(parsed.path) do
      session_id = Keyword.fetch!(opts, :session_id)
      cwd = Keyword.fetch!(opts, :cwd)

      base_dir = notes_dir(cwd, session_id)
      resolved = Path.join(base_dir, parsed.path)

      # Final safety check: ensure resolved path is under base_dir
      expanded = Path.expand(resolved)
      expanded_base = Path.expand(base_dir)

      if String.starts_with?(expanded, expanded_base <> "/") do
        fallback_ids = Keyword.get(opts, :fallback_session_ids, [])
        {:ok, resolve_with_fallback(expanded, parsed.path, cwd, fallback_ids)}
      else
        {:error, :path_traversal}
      end
    end
  end

  # ============================================================================
  # File Listing
  # ============================================================================

  @doc """
  List files in the notes directory for a session.

  ## Parameters

    * `opts` - Options with session context

  ## Options

    * `:session_id` - The session ID (required)
    * `:cwd` - The current working directory (required)

  ## Returns

    * `{:ok, files}` - List of relative file paths in the notes directory
  """
  @spec list_files(keyword()) :: {:ok, [String.t()]}
  def list_files(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    cwd = Keyword.fetch!(opts, :cwd)
    dir = notes_dir(cwd, session_id)

    if File.dir?(dir) do
      files =
        dir
        |> list_recursive()
        |> Enum.map(&Path.relative_to(&1, dir))
        |> Enum.sort()

      {:ok, files}
    else
      {:ok, []}
    end
  end

  # ============================================================================
  # Plan Finalization
  # ============================================================================

  @doc """
  Rename a plan artifact to mark it as approved.

  Renames a draft plan file (e.g., `plan.md`) to an approved plan file
  (e.g., `approved-plan.md`) within the session's notes directory.

  ## Parameters

    * `source_name` - The source file name (e.g., "plan.md")
    * `target_name` - The target file name (e.g., "approved-plan.md")
    * `opts` - Options with session context

  ## Options

    * `:session_id` - The session ID (required)
    * `:cwd` - The current working directory (required)

  ## Returns

    * `:ok` - Successfully renamed
    * `{:error, reason}` - Rename failure
  """
  @spec rename_approved_plan(String.t(), String.t(), keyword()) :: :ok | {:error, atom()}
  def rename_approved_plan(source_name, target_name, opts) do
    with :ok <- validate_path(source_name),
         :ok <- validate_path(target_name) do
      session_id = Keyword.fetch!(opts, :session_id)
      cwd = Keyword.fetch!(opts, :cwd)
      dir = notes_dir(cwd, session_id)

      source = Path.join(dir, source_name)
      target = Path.join(dir, target_name)

      if File.exists?(source) do
        File.mkdir_p!(Path.dirname(target))

        case File.rename(source, target) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :source_not_found}
      end
    end
  end

  # ============================================================================
  # Directory Management
  # ============================================================================

  @doc """
  Get the notes directory path for a session.

  ## Parameters

    * `cwd` - The current working directory
    * `session_id` - The session ID

  ## Returns

  The filesystem path to the session's notes directory.
  """
  @spec notes_dir(String.t(), String.t()) :: String.t()
  def notes_dir(cwd, session_id) do
    Path.join([Config.sessions_dir(cwd), @notes_dir, session_id])
  end

  @doc """
  Ensure the notes directory exists for a session.

  ## Parameters

    * `cwd` - The current working directory
    * `session_id` - The session ID

  ## Returns

    * `:ok`
  """
  @spec ensure_notes_dir!(String.t(), String.t()) :: :ok
  def ensure_notes_dir!(cwd, session_id) do
    dir = notes_dir(cwd, session_id)
    File.mkdir_p!(dir)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp validate_path(path) do
    cond do
      String.contains?(path, "..") ->
        {:error, :path_traversal}

      Path.type(path) == :absolute ->
        {:error, :path_traversal}

      String.contains?(path, "\0") ->
        {:error, :invalid_path}

      true ->
        :ok
    end
  end

  defp resolve_with_fallback(primary_path, _relative_path, _cwd, []) do
    primary_path
  end

  defp resolve_with_fallback(primary_path, relative_path, cwd, fallback_ids) do
    if File.exists?(primary_path) do
      primary_path
    else
      Enum.find_value(fallback_ids, primary_path, fn fallback_id ->
        candidate = Path.join(notes_dir(cwd, fallback_id), relative_path)
        expanded = Path.expand(candidate)
        if File.exists?(expanded), do: expanded
      end)
    end
  end

  defp list_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          if File.dir?(path) do
            list_recursive(path)
          else
            [path]
          end
        end)

      {:error, _} ->
        []
    end
  end
end
