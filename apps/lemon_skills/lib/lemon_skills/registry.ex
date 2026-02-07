defmodule LemonSkills.Registry do
  @moduledoc """
  GenServer for caching and managing skill entries.

  The registry maintains an in-memory cache of all available skills,
  loading them from disk on startup and providing fast lookups.

  ## Architecture

  Skills are loaded from two locations:
  1. Global: `~/.lemon/agent/skill/*/SKILL.md`
  2. Project: `<cwd>/.lemon/skill/*/SKILL.md`

  Project skills override global skills with the same key.
  """

  use GenServer

  alias LemonSkills.{Entry, Manifest, Config}

  @type state :: %{
          global_skills: %{String.t() => Entry.t()},
          project_skills: %{String.t() => %{String.t() => Entry.t()}}
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the registry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List all available skills.

  ## Options

  - `:cwd` - Project working directory (optional)
  - `:refresh` - Force refresh from disk (default: false)
  """
  @spec list(keyword()) :: [Entry.t()]
  def list(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    refresh = Keyword.get(opts, :refresh, false)

    if refresh do
      refresh(opts)
    end

    GenServer.call(__MODULE__, {:list, cwd})
  end

  @doc """
  Return counts useful for status UIs.

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec counts(keyword()) :: %{installed: non_neg_integer(), enabled: non_neg_integer()}
  def counts(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)

    skills = list(cwd: cwd)
    installed = length(skills)

    enabled =
      Enum.count(skills, fn entry ->
        entry.enabled and not Config.skill_disabled?(entry.key, cwd)
      end)

    %{installed: installed, enabled: enabled}
  rescue
    _ -> %{installed: 0, enabled: 0}
  end

  @doc """
  Get a skill by key.

  ## Parameters

  - `key` - The skill key/identifier

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec get(String.t(), keyword()) :: {:ok, Entry.t()} | :error
  def get(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    GenServer.call(__MODULE__, {:get, key, cwd})
  end

  @doc """
  Refresh the skill registry.

  Forces a reload of all skills from disk.

  ## Options

  - `:cwd` - Project working directory (optional, refreshes specific project)
  """
  @spec refresh(keyword()) :: :ok
  def refresh(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    GenServer.call(__MODULE__, {:refresh, cwd})
  end

  @doc """
  Register a new skill entry.

  Used by the installer to add newly installed skills.

  ## Parameters

  - `entry` - The skill entry to register
  """
  @spec register(Entry.t()) :: :ok
  def register(%Entry{} = entry) do
    GenServer.call(__MODULE__, {:register, entry})
  end

  @doc """
  Unregister a skill entry.

  ## Parameters

  - `key` - The skill key to remove
  - `source` - The source (:global or :project)
  - `cwd` - Project working directory (for project skills)
  """
  @spec unregister(String.t(), atom(), String.t() | nil) :: :ok
  def unregister(key, source, cwd \\ nil) do
    GenServer.call(__MODULE__, {:unregister, key, source, cwd})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      global_skills: %{},
      project_skills: %{}
    }

    # Load global skills on startup
    state = load_global_skills(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:list, cwd}, _from, state) do
    skills = merge_skills(state, cwd)
    {:reply, Map.values(skills), state}
  end

  @impl true
  def handle_call({:get, key, cwd}, _from, state) do
    skills = merge_skills(state, cwd)

    result =
      case Map.fetch(skills, key) do
        {:ok, entry} -> {:ok, entry}
        :error -> :error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:refresh, nil}, _from, state) do
    state = load_global_skills(%{state | global_skills: %{}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:refresh, cwd}, _from, state) do
    state = load_project_skills(state, cwd)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register, entry}, _from, state) do
    state = add_entry(state, entry)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key, :global, _cwd}, _from, state) do
    state = %{state | global_skills: Map.delete(state.global_skills, key)}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key, :project, cwd}, _from, state) when is_binary(cwd) do
    project_skills = Map.get(state.project_skills, cwd, %{})
    project_skills = Map.delete(project_skills, key)
    state = %{state | project_skills: Map.put(state.project_skills, cwd, project_skills)}
    {:reply, :ok, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_global_skills(state) do
    dir = Config.global_skills_dir()
    skills = load_skills_from_dir(dir, :global)
    %{state | global_skills: skills}
  end

  defp load_project_skills(state, cwd) when is_binary(cwd) do
    dir = Config.project_skills_dir(cwd)
    skills = load_skills_from_dir(dir, :project)
    project_skills = Map.put(state.project_skills, cwd, skills)
    %{state | project_skills: project_skills}
  end

  defp load_skills_from_dir(dir, source) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        path = Path.join(dir, name)
        File.dir?(path) and File.exists?(Path.join(path, "SKILL.md"))
      end)
      |> Enum.map(fn name ->
        path = Path.join(dir, name)
        load_skill_entry(path, source)
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn entry -> {entry.key, entry} end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp load_skill_entry(path, source) do
    entry = Entry.new(path, source: source)
    skill_file = Entry.skill_file(entry)

    case File.read(skill_file) do
      {:ok, content} ->
        case Manifest.parse(content) do
          {:ok, manifest, _body} ->
            Entry.with_manifest(entry, manifest)

          :error ->
            # Skill file exists but has no/invalid frontmatter
            entry
        end

      {:error, _} ->
        nil
    end
  end

  defp merge_skills(state, nil) do
    state.global_skills
  end

  defp merge_skills(state, cwd) do
    # Ensure project skills are loaded
    project_skills =
      case Map.fetch(state.project_skills, cwd) do
        {:ok, skills} -> skills
        :error -> load_skills_from_dir(Config.project_skills_dir(cwd), :project)
      end

    # Project skills override global
    Map.merge(state.global_skills, project_skills)
  end

  defp add_entry(state, %Entry{source: :global} = entry) do
    %{state | global_skills: Map.put(state.global_skills, entry.key, entry)}
  end

  defp add_entry(state, %Entry{source: :project, path: path} = entry) do
    # Derive cwd from path
    cwd = path |> Path.dirname() |> Path.dirname() |> Path.dirname()
    project_skills = Map.get(state.project_skills, cwd, %{})
    project_skills = Map.put(project_skills, entry.key, entry)
    %{state | project_skills: Map.put(state.project_skills, cwd, project_skills)}
  end

  defp add_entry(state, entry) do
    # Default to global for other sources (URLs, etc.)
    %{state | global_skills: Map.put(state.global_skills, entry.key, entry)}
  end
end
