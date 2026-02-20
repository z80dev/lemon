defmodule LemonSkills.Registry do
  @moduledoc """
  GenServer for caching and managing skill entries.

  The registry maintains an in-memory cache of all available skills,
  loading them from disk on startup and providing fast lookups.

  ## Architecture

  Skills are loaded from global and project locations:
  1. Global (primary): `~/.lemon/agent/skill/*/SKILL.md`
  2. Global (compat): `~/.agents/skills/*/SKILL.md`
  3. Project: `<cwd>/.lemon/skill/*/SKILL.md`

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
  Find skills relevant to a given context/query.

  Uses simple keyword matching on key/name/description/body content.

  ## Options

  - `:cwd` - Project working directory (optional)
  - `:max_results` - Maximum results (default: 3)
  - `:refresh` - Force refresh from disk before searching (default: false)
  """
  @spec find_relevant(String.t(), keyword()) :: [Entry.t()]
  def find_relevant(context, opts \\ []) when is_binary(context) do
    cwd = Keyword.get(opts, :cwd)
    max_results = Keyword.get(opts, :max_results, 3)
    refresh? = Keyword.get(opts, :refresh, false)

    if refresh? do
      refresh(cwd: cwd)
    end

    GenServer.call(__MODULE__, {:find_relevant, cwd, context, max_results})
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
    {skills, state} = merge_skills(state, cwd)
    {:reply, Map.values(skills), state}
  end

  @impl true
  def handle_call({:get, key, cwd}, _from, state) do
    {skills, state} = merge_skills(state, cwd)

    result =
      case Map.fetch(skills, key) do
        {:ok, entry} -> {:ok, entry}
        :error -> :error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_relevant, cwd, context, max_results}, _from, state) do
    {skills, state} = merge_skills(state, cwd)

    context_lower = String.downcase(context)
    context_words = extract_words(context_lower)

    entries =
      skills
      |> Map.values()
      |> Enum.filter(fn entry ->
        entry.enabled and not Config.skill_disabled?(entry.key, cwd)
      end)
      |> Enum.map(fn entry ->
        score =
          calculate_relevance(entry, context_lower, context_words) +
            source_priority_bonus(entry)

        {entry, score}
      end)
      |> Enum.filter(fn {_entry, score} -> score > 0 end)
      |> Enum.sort_by(fn {_entry, score} -> score end, :desc)
      |> Enum.take(max_results)
      |> Enum.map(fn {entry, _score} -> entry end)

    {:reply, entries, state}
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
    skills =
      Config.global_skills_dirs()
      |> Enum.reduce(%{}, fn dir, acc ->
        dir_skills = load_skills_from_dir(dir, :global)

        # Keep first-seen entries so directory order controls precedence.
        Map.merge(acc, dir_skills, fn _key, existing, _incoming -> existing end)
      end)

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

  defp merge_skills(state, nil), do: {state.global_skills, state}

  defp merge_skills(state, cwd) do
    state = ensure_project_loaded(state, cwd)
    project_skills = Map.get(state.project_skills, cwd, %{})

    # Project skills override global.
    {Map.merge(state.global_skills, project_skills), state}
  end

  defp ensure_project_loaded(state, cwd) when is_binary(cwd) do
    case Map.fetch(state.project_skills, cwd) do
      {:ok, _skills} ->
        state

      :error ->
        load_project_skills(state, cwd)
    end
  end

  defp ensure_project_loaded(state, _cwd), do: state

  defp calculate_relevance(%Entry{} = entry, context_lower, context_words) do
    key_lower = String.downcase(entry.key || "")
    name_lower = String.downcase(entry.name || entry.key || "")
    desc_lower = String.downcase(entry.description || "")

    # Read and score against the body content as a low-weight signal.
    body_lower =
      case Entry.content(entry) do
        {:ok, content} ->
          content
          |> Manifest.parse_body()
          |> String.slice(0, 10_000)
          |> String.downcase()

        _ ->
          ""
      end

    # Extract keywords from manifest if available
    keywords_lower =
      case entry.manifest do
        %{keywords: keywords} when is_list(keywords) ->
          Enum.map(keywords, &String.downcase/1)

        _ ->
          []
      end

    # Calculate name scores (strongest signal)
    exact_name_match =
      if key_lower == context_lower or name_lower == context_lower,
        do: 100,
        else: 0

    partial_name_match =
      if exact_name_match == 0 and
           (String.contains?(key_lower, context_lower) or String.contains?(name_lower, context_lower)),
         do: 50,
         else: 0

    context_in_name_match =
      if String.contains?(context_lower, key_lower) or String.contains?(context_lower, name_lower),
        do: 30,
        else: 0

    name_score =
      exact_name_match
      |> max(partial_name_match)
      |> max(context_in_name_match)

    # Keyword matches (strong signal for curated skills)
    keyword_score =
      Enum.reduce(context_words, 0, fn word, acc ->
        exact_keyword_match =
          Enum.any?(keywords_lower, fn kw -> kw == word end)

        partial_keyword_match =
          Enum.any?(keywords_lower, fn kw -> String.contains?(kw, word) end)

        cond do
          exact_keyword_match -> acc + 40
          partial_keyword_match -> acc + 20
          true -> acc
        end
      end)

    # Description word matches (medium signal)
    desc_word_matches =
      context_words
      |> Enum.count(fn word -> String.contains?(desc_lower, word) end)

    desc_score = desc_word_matches * 10

    # Body content matches (weakest signal)
    body_word_matches =
      context_words
      |> Enum.count(fn word -> String.contains?(body_lower, word) end)

    body_score = body_word_matches * 2

    name_score + keyword_score + desc_score + body_score
  end

  # Prefer project-local skills over global ones when both are relevant.
  defp source_priority_bonus(%Entry{source: :project}), do: 1000
  defp source_priority_bonus(_), do: 0

  defp extract_words(text) when is_binary(text) do
    text
    |> String.split(~r/[^\w]+/)
    |> Enum.filter(fn word -> String.length(word) > 2 end)
    |> Enum.uniq()
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
