defmodule CodingAgent.Workspace do
  @moduledoc """
  Loads assistant workspace files (identity + memory) from ~/.lemon/agent/workspace.

  These files are injected into the system prompt as stable context:
  - AGENTS.md
  - SOUL.md
  - TOOLS.md
  - IDENTITY.md
  - USER.md
  - HEARTBEAT.md
  - BOOTSTRAP.md
  - MEMORY.md (optional; only included for main sessions)
  """

  alias CodingAgent.Config

  @default_max_chars 20_000
  @head_ratio 0.7
  @tail_ratio 0.2

  @required_files [
    "AGENTS.md",
    "SOUL.md",
    "TOOLS.md",
    "IDENTITY.md",
    "USER.md",
    "HEARTBEAT.md",
    "BOOTSTRAP.md"
  ]

  @memory_file "MEMORY.md"
  @subagent_bootstrap_allowlist MapSet.new(["AGENTS.md", "TOOLS.md"])

  @type session_scope :: :main | :subagent

  @type bootstrap_file :: %{
          name: String.t(),
          path: String.t(),
          content: String.t(),
          missing: boolean()
        }

  @spec default_max_chars() :: pos_integer()
  def default_max_chars, do: @default_max_chars

  @spec workspace_dir() :: String.t()
  def workspace_dir, do: Config.workspace_dir()

  @doc """
  Initialize the workspace directory by writing missing template files.

  Options:
    - :workspace_dir (override default workspace)
    - :template_dir (override templates location)
  """
  @spec ensure_workspace(keyword()) :: :ok
  def ensure_workspace(opts \\ []) do
    dir = Keyword.get(opts, :workspace_dir, workspace_dir())
    template_dir = Keyword.get(opts, :template_dir, workspace_template_dir())

    File.mkdir_p!(dir)

    templates = list_template_files(template_dir)

    Enum.each(templates, fn {name, template_path} ->
      target = Path.join(dir, name)

      case File.open(target, [:write, :exclusive]) do
        {:ok, io} ->
          File.stream!(template_path)
          |> Enum.each(&IO.write(io, &1))

          File.close(io)

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          raise "Failed to write #{target}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @spec workspace_template_dir() :: String.t()
  def workspace_template_dir do
    priv = :code.priv_dir(:coding_agent) |> to_string()
    Path.join([priv, "templates", "workspace"])
  end

  @doc """
  Load workspace bootstrap files, returning content (or missing markers).

  Options:
    - :workspace_dir (override default workspace)
    - :max_chars (truncate long files; default #{@default_max_chars})
    - :session_scope (:main or :subagent; default inferred from :parent_session)
    - :parent_session (when present, inferred as :subagent)
  """
  @spec load_bootstrap_files(keyword()) :: [bootstrap_file()]
  def load_bootstrap_files(opts \\ []) do
    dir = Keyword.get(opts, :workspace_dir, workspace_dir())
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    session_scope = resolve_session_scope(opts)

    required =
      @required_files
      |> Enum.map(&load_required_file(dir, &1, max_chars))

    memory =
      case find_first_existing_exact(dir, [@memory_file]) do
        nil ->
          []

        name ->
          case load_optional_file(dir, name, max_chars) do
            nil -> []
            file -> [file]
          end
      end

    (required ++ memory)
    |> filter_bootstrap_files_for_session(session_scope)
  end

  @doc """
  Filter bootstrap files for a session scope.

  Main sessions receive full bootstrap context. Subagent sessions only receive
  AGENTS.md and TOOLS.md to avoid leaking durable personal memory/context.
  """
  @spec filter_bootstrap_files_for_session([bootstrap_file()], session_scope() | String.t()) ::
          [bootstrap_file()]
  def filter_bootstrap_files_for_session(files, session_scope)
      when session_scope in [:main, "main"] do
    files
  end

  def filter_bootstrap_files_for_session(files, session_scope)
      when session_scope in [:subagent, "subagent"] do
    Enum.filter(files, fn file ->
      MapSet.member?(@subagent_bootstrap_allowlist, file.name)
    end)
  end

  def filter_bootstrap_files_for_session(files, _session_scope), do: files

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp load_required_file(dir, name, max_chars) do
    path = Path.join(dir, name)

    case File.read(path) do
      {:ok, content} ->
        trimmed = trim_content(content, name, max_chars)

        %{
          name: name,
          path: path,
          content: trimmed,
          missing: false
        }

      {:error, _} ->
        %{
          name: name,
          path: path,
          content: "[MISSING] Expected at: #{path}",
          missing: true
        }
    end
  end

  defp load_optional_file(dir, name, max_chars) do
    path = Path.join(dir, name)

    case File.read(path) do
      {:ok, content} ->
        trimmed = trim_content(content, name, max_chars)

        %{
          name: name,
          path: path,
          content: trimmed,
          missing: false
        }

      {:error, _} ->
        # Optional files are omitted if missing.
        nil
    end
  end

  defp find_first_existing_exact(dir, names) do
    entries =
      case File.ls(dir) do
        {:ok, files} -> MapSet.new(files)
        {:error, _} -> MapSet.new()
      end

    Enum.find(names, fn name ->
      MapSet.member?(entries, name) and File.regular?(Path.join(dir, name))
    end)
  end

  defp resolve_session_scope(opts) do
    case Keyword.get(opts, :session_scope) do
      scope when scope in [:main, "main"] ->
        :main

      scope when scope in [:subagent, "subagent"] ->
        :subagent

      _ ->
        parent_session = Keyword.get(opts, :parent_session)

        if is_binary(parent_session) and String.trim(parent_session) != "",
          do: :subagent,
          else: :main
    end
  end

  defp list_template_files(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        path = Path.join(dir, name)
        File.regular?(path)
      end)
      |> Enum.map(fn name -> {name, Path.join(dir, name)} end)
    else
      []
    end
  end

  defp trim_content(content, file_name, max_chars) do
    trimmed = String.trim_trailing(content)

    if String.length(trimmed) <= max_chars do
      trimmed
    else
      head_chars = max(1, floor(max_chars * @head_ratio))
      tail_chars = max(1, floor(max_chars * @tail_ratio))
      head = String.slice(trimmed, 0, head_chars)
      tail = String.slice(trimmed, -tail_chars, tail_chars)

      marker =
        [
          "",
          "[...truncated, read #{file_name} for full content...]",
          "…(truncated #{file_name}: kept #{head_chars}+#{tail_chars} chars of #{String.length(trimmed)})…",
          ""
        ]
        |> Enum.join("\n")

      [head, marker, tail]
      |> Enum.join("\n")
    end
  end
end
