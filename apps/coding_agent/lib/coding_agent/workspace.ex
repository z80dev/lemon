defmodule CodingAgent.Workspace do
  @moduledoc """
  Loads assistant workspace files (identity + memory) from ~/.lemon/agent/workspace.

  These files are injected into the system prompt as stable context:
  - AGENTS.md
  - SOUL.md
  - TOOLS.md
  - IDENTITY.md
  - USER.md (raw file only for legacy unscoped sessions)
  - HEARTBEAT.md
  - BOOTSTRAP.md
  - MEMORY.md (legacy optional file, main sessions only)

  Context-owned main sessions replace personal file reads with exact canonical
  shared fact projections from the existing memory owner. Unknown legacy bytes
  remain unchanged, never inferred shared. Private preferences belong in volatile
  recall, not the static prefix; missing proof/store availability never falls back.
  """

  alias CodingAgent.Config
  alias LemonMemory.{ContextScope, Preferences}

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
  @profile_instruction_files ~w(AGENTS.md IDENTITY.md README.md SOUL.md)

  @doc """
  Validate a JSON-safe, content-only profile persona snapshot.

  Mutable USER.md and MEMORY.md belong to the destination workspace, not the
  controller snapshot. Snapshots containing either file are rejected.
  """
  def validate_profile_instructions(nil), do: :ok

  def validate_profile_instructions(files) when is_map(files) do
    if Enum.all?(files, fn {name, text} ->
         name in @profile_instruction_files and is_binary(text) and String.valid?(text) and
           not String.contains?(text, <<0>>)
       end),
       do: :ok,
       else: {:error, :invalid_profile_instructions}
  end

  def validate_profile_instructions(_), do: {:error, :invalid_profile_instructions}

  @type session_scope :: :main | :subagent

  @type bootstrap_file :: %{
          optional(:source) => :verified_shared_memory,
          name: String.t(),
          path: String.t(),
          content: String.t(),
          missing: boolean()
        }

  @spec default_max_chars() :: pos_integer()
  def default_max_chars, do: @default_max_chars

  @spec workspace_dir() :: String.t()
  def workspace_dir, do: Config.workspace_dir()

  @doc "Whether a native session is bound to its validated profile workspace."
  def profile_owned?(opts) do
    case LemonCore.ProfileStore.paths(scope_opt(opts, :agent_id)) do
      {:ok, %{"workspace" => workspace}} -> scope_opt(opts, :workspace_dir) == workspace
      _ -> false
    end
  end

  @doc """
  Skill lookup root for profile sessions, independent of execution project cwd.
  Registry metadata and lazy `read_skill` resolve the same destination-owned
  `.lemon/skill` tree. Generic sessions retain their project cwd.
  """
  def skill_cwd(cwd, opts) do
    if profile_owned?(opts), do: scope_opt(opts, :workspace_dir), else: cwd
  end

  defp scope_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp scope_opt(opts, key) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key)))

  defp scope_opt(_, _), do: nil

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

    Enum.each(templates, fn {relative_path, template_path} ->
      target = Path.join(dir, relative_path)
      File.mkdir_p!(Path.dirname(target))

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
    - :profile_instructions (persona-only controller snapshot; never written to disk)
    - :parent_session (when present, inferred as :subagent)
    - :invocation_context_key / :memory_context_key / :memory_context_verified
      (admitted native ownership; model metadata is not proof)
    - :shared_memory_grant (trusted runtime authority, not inferred from key presence)
    - :cwd / :agent_id / :session_key (owning profile/repository context)
    - :memory_store (existing owner server; defaults to LemonMemory.Store)
  """
  @spec load_bootstrap_files(keyword()) :: [bootstrap_file()]
  def load_bootstrap_files(opts \\ []) do
    dir = Keyword.get(opts, :workspace_dir, workspace_dir())
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    session_scope = resolve_session_scope(opts)
    profile_instructions = Keyword.get(opts, :profile_instructions)

    if validate_profile_instructions(profile_instructions) != :ok,
      do: raise(ArgumentError, "invalid profile instruction snapshot")

    context =
      opts
      |> Keyword.take([
        :agent_id,
        :session_key,
        :invocation_context_key,
        :memory_context_key,
        :memory_context_verified,
        :shared_memory_grant
      ])
      |> Map.new()
      |> Map.merge(%{
        workspace_dir: dir,
        cwd: Keyword.get(opts, :cwd, dir),
        session_scope: session_scope
      })

    memory_scope = ContextScope.scope(context)

    required_names =
      cond do
        session_scope == :subagent ->
          Enum.filter(@required_files, &MapSet.member?(@subagent_bootstrap_allowlist, &1))

        memory_scope == {:ok, :legacy} ->
          @required_files

        true ->
          List.delete(@required_files, "USER.md")
      end

    required =
      required_names
      |> Enum.reject(&(is_map(profile_instructions) and &1 in @profile_instruction_files))
      |> Enum.map(&load_required_file(dir, &1, max_chars))

    memory =
      cond do
        session_scope == :subagent -> []
        memory_scope == {:ok, :legacy} -> legacy_memory_file(dir, max_chars)
        true -> verified_shared_preferences(context, opts, max_chars)
      end

    (overlay_profile_instructions(required, profile_instructions, dir, max_chars) ++ memory)
    |> filter_bootstrap_files_for_session(session_scope)
  end

  defp legacy_memory_file(dir, max_chars) do
    case find_first_existing_exact(dir, [@memory_file]) do
      nil ->
        []

      name ->
        case load_optional_file(dir, name, max_chars) do
          nil -> []
          file -> [file]
        end
    end
  end

  defp verified_shared_preferences(context, opts, max_chars) do
    store_opts =
      if Keyword.has_key?(opts, :memory_store),
        do: [store: Keyword.fetch!(opts, :memory_store)],
        else: []

    case Preferences.shared_bootstrap(context, store_opts) do
      {:ok, files} ->
        Enum.flat_map(["USER.md", "MEMORY.md"], fn name ->
          case files[name] do
            text when is_binary(text) and text != "" ->
              [
                %{
                  name: name,
                  path: Path.join(context.workspace_dir, name),
                  content: trim_content(text, name, max_chars),
                  missing: false,
                  source: :verified_shared_memory
                }
              ]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Filter bootstrap files for a session scope.

  Main sessions receive the already-admitted bootstrap projections. Subagents
  only receive AGENTS.md and TOOLS.md, never personal files or shared preference projections.
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

  # Omitted persona files must not pick up a stale destination persona.
  # USER.md, TOOLS.md, MEMORY.md and other local files stay destination-owned.
  defp overlay_profile_instructions(files, nil, _dir, _max_chars), do: files

  defp overlay_profile_instructions(files, snapshot, dir, max_chars) do
    local_files = Enum.reject(files, &(&1.name in @profile_instruction_files))

    persona_files =
      Enum.flat_map(@profile_instruction_files, fn name ->
        case Map.fetch(snapshot, name) do
          {:ok, text} ->
            [
              %{
                name: name,
                path: Path.join(dir, name),
                content: trim_content(text, name, max_chars),
                missing: false
              }
            ]

          :error ->
            []
        end
      end)

    persona_files ++ local_files
  end

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
      do_list_template_files(dir, "")
      |> Enum.sort_by(fn {relative_path, _abs_path} -> relative_path end)
    else
      []
    end
  end

  defp do_list_template_files(dir, prefix) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      abs_path = Path.join(dir, name)
      relative_path = if prefix == "", do: name, else: Path.join(prefix, name)

      cond do
        File.regular?(abs_path) ->
          [{relative_path, abs_path}]

        File.dir?(abs_path) ->
          do_list_template_files(abs_path, relative_path)

        true ->
          []
      end
    end)
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
