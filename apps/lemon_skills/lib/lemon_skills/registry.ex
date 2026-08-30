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
  4. Ancestor `.agents/skills`: `.agents/skills/*/SKILL.md` from cwd up to git root

  Project skills override global skills with the same key.
  Ancestor `.agents/skills` directories are discovered automatically,
  following Pi's package-manager pattern.

  ## Online Discovery

  The registry also supports discovering skills from online sources:

      # Search GitHub for skills matching a query
      results = LemonSkills.Registry.discover("github")

      # Search both local and online skills
      %{local: local_skills, online: online_skills} =
        LemonSkills.Registry.search("api")

  See `LemonSkills.Discovery` for more details on online discovery.
  """

  use GenServer

  alias LemonSkills.{Entry, Manifest, Config, Discovery, Lockfile}

  @identity_check_interval_ms 50

  @type state :: %{
          global_skills: %{String.t() => Entry.t()},
          project_skills: %{String.t() => %{String.t() => Entry.t()}},
          global_search: map(),
          project_search: map(),
          global_identity: term(),
          project_identities: %{String.t() => term()},
          global_identity_checked_at: integer() | nil,
          project_identity_checked_at: %{String.t() => integer() | nil}
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
    else
      ensure_current(cwd)
    end

    GenServer.call(__MODULE__, {:list, cwd})
  end

  @doc false
  @spec list_views(keyword()) :: [LemonSkills.SkillView.t()]
  def list_views(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    disabled = disabled_keys(cwd)

    opts
    |> list()
    |> Enum.map(&LemonSkills.SkillView.from_entry(&1, cwd: cwd, disabled_keys: disabled))
  end

  @doc """
  List all available skills grouped by category.

  Returns a map where keys are category strings and values are lists of
  skill entries. Skills without a `metadata.lemon.category` in their
  manifest are grouped under `"uncategorized"`.

  Categories are sorted alphabetically, and skills within each category
  are sorted by key.

  ## Options

  - `:cwd` - Project working directory (optional)
  - `:refresh` - Force refresh from disk (default: false)

  ## Examples

      %{
        "devops" => [%Entry{key: "k8s-rollout", ...}],
        "ml-training" => [%Entry{key: "axolotl", ...}],
        "uncategorized" => [%Entry{key: "misc-skill", ...}]
      } = LemonSkills.Registry.list_by_category()
  """
  @spec list_by_category(keyword()) :: %{String.t() => [Entry.t()]}
  def list_by_category(opts \\ []) do
    opts
    |> list()
    |> Enum.group_by(fn entry ->
      (entry.manifest && Manifest.lemon_category(entry.manifest)) || "uncategorized"
    end)
    |> Enum.sort_by(fn {category, _} -> category end)
    |> Map.new()
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
    else
      ensure_current(cwd)
    end

    documents = GenServer.call(__MODULE__, {:search_snapshot, cwd})
    score_documents(documents, context, max_results, disabled_keys(cwd))
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
    ensure_current(cwd)
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
    {global_identity, project_identity} = cache_identity(cwd)
    GenServer.call(__MODULE__, {:refresh, cwd, global_identity, project_identity})
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

  @doc """
  Discover skills from online sources.

  Searches GitHub and other registries for skills matching the query.
  Returns discovered skills that can be installed.

  ## Parameters

  - `query` - Search query string (e.g., "github", "web search")

  ## Options

  - `:timeout` - Overall timeout in milliseconds (default: 10000)
  - `:max_results` - Maximum results to return (default: 10)
  - `:github_token` - GitHub personal access token for higher rate limits

  ## Returns

  List of discovery results with entry, source, validated status, and URL.

  ## Examples

      # Discover GitHub-related skills
      results = LemonSkills.Registry.discover("github")

      # Each result can be installed
      [%{entry: %Entry{}, source: :github, validated: false, url: "..."}, ...]
  """
  @spec discover(String.t(), keyword()) :: [Discovery.discovery_result()]
  def discover(query, opts \\ []) do
    Discovery.discover(query, opts)
  end

  @doc """
  Search both local and online skills for a query.

  Combines local skill search with online discovery for comprehensive results.

  ## Options

  - `:cwd` - Project working directory (optional)
  - `:max_local` - Maximum local results (default: 3)
  - `:max_online` - Maximum online results (default: 5)
  - `:include_online` - Whether to include online discovery (default: true)
  """
  @spec search(String.t(), keyword()) :: %{
          local: [Entry.t()],
          online: [Discovery.discovery_result()]
        }
  def search(query, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    max_local = Keyword.get(opts, :max_local, 3)
    max_online = Keyword.get(opts, :max_online, 5)
    include_online = Keyword.get(opts, :include_online, true)

    local = find_relevant(query, cwd: cwd, max_results: max_local)

    online =
      if include_online do
        Discovery.discover(query, max_results: max_online)
      else
        []
      end

    %{local: local, online: online}
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      global_skills: %{},
      project_skills: %{},
      global_search: %{},
      project_search: %{},
      global_identity: nil,
      project_identities: %{},
      global_identity_checked_at: nil,
      project_identity_checked_at: %{}
    }

    # Load global skills on startup
    {global_identity, _project_identity} = cache_identity(nil)

    state = %{
      load_global_skills(state)
      | global_identity: global_identity,
        global_identity_checked_at: monotonic_ms()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:list, cwd}, _from, state) do
    {skills, state} = merge_skills(state, cwd)

    # NOTE: Map iteration order is not guaranteed.
    # We sort here to keep skill ordering deterministic across calls.
    # This is important for stable system prompts (and prompt caching).
    entries =
      skills
      |> Map.values()
      |> Enum.sort_by(fn entry -> entry.key || "" end)

    {:reply, entries, state}
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
  def handle_call({:search_snapshot, cwd}, _from, state) do
    state = ensure_project_loaded(state, cwd)

    documents =
      if is_binary(cwd) do
        Map.get(state.project_search, cwd, %{})
      else
        state.global_search
      end

    {:reply, Map.values(documents), state}
  end

  @impl true
  def handle_call({:refresh, nil, global_identity, _project_identity}, _from, state) do
    state =
      load_global_skills(%{
        state
        | global_skills: %{},
          global_search: %{},
          project_skills: %{},
          project_search: %{},
          project_identities: %{},
          project_identity_checked_at: %{}
      })

    {:reply, :ok,
     %{
       state
       | global_identity: global_identity,
         global_identity_checked_at: monotonic_ms()
     }}
  end

  def handle_call(
        {:refresh, cwd, global_identity, project_identity},
        _from,
        state
      ) do
    state = maybe_reload_global(state, global_identity)
    state = load_project_skills(state, cwd)

    {:reply, :ok,
     %{
       state
       | project_identities: Map.put(state.project_identities, cwd, project_identity),
         project_identity_checked_at:
           Map.put(state.project_identity_checked_at, cwd, monotonic_ms())
     }}
  end

  @impl true
  def handle_call({:reserve_identity_check, cwd, now}, _from, state) do
    check_global? = identity_check_due?(state.global_identity_checked_at, now)

    check_project? =
      is_binary(cwd) and
        identity_check_due?(Map.get(state.project_identity_checked_at, cwd), now)

    state =
      if check_global? do
        %{state | global_identity_checked_at: now}
      else
        state
      end

    state =
      if check_project? do
        %{
          state
          | project_identity_checked_at: Map.put(state.project_identity_checked_at, cwd, now)
        }
      else
        state
      end

    {:reply, {check_global?, check_project?}, state}
  end

  @impl true
  def handle_call(
        {:ensure_current, cwd, global_identity, project_identity},
        _from,
        state
      ) do
    state = maybe_reload_global(state, global_identity)
    state = maybe_reload_project(state, cwd, project_identity)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register, entry}, _from, state) do
    state = add_entry(state, entry)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key, :global, _cwd}, _from, state) do
    global_skills = Map.delete(state.global_skills, key)
    state = rebuild_global_derived(%{state | global_skills: global_skills})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, key, :project, cwd}, _from, state) when is_binary(cwd) do
    project_skills = Map.get(state.project_skills, cwd, %{})
    project_skills = Map.delete(project_skills, key)
    state = %{state | project_skills: Map.put(state.project_skills, cwd, project_skills)}
    state = rebuild_project_derived(state, cwd)
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

    # Hydrate provenance from the global lockfile where records are present.
    skills = hydrate_from_lockfile(skills, :global)

    rebuild_global_derived(%{state | global_skills: skills})
  end

  defp load_project_skills(state, cwd) when is_binary(cwd) do
    # Load skills from all project directories including .agents/skills paths
    skills =
      Config.project_skills_dirs(cwd)
      |> Enum.reduce(%{}, fn dir, acc ->
        dir_skills = load_skills_from_dir(dir, :project)

        # Keep first-seen entries so directory order controls precedence.
        # Project .lemon/skill has highest precedence, then .agents/skills
        # from cwd up to git root.
        Map.merge(acc, dir_skills, fn _key, existing, _incoming -> existing end)
      end)

    # Hydrate provenance from the project lockfile where records are present.
    skills = hydrate_from_lockfile(skills, {:project, cwd})

    project_skills = Map.put(state.project_skills, cwd, skills)
    state = %{state | project_skills: project_skills}
    rebuild_project_derived(state, cwd)
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
        case Manifest.parse_and_validate(content) do
          {:ok, manifest, _body} ->
            Entry.with_manifest(entry, manifest)

          {:error, _reason} ->
            nil
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

  defp calculate_relevance(document, context_lower, context_words) do
    key_lower = document.key_lower
    name_lower = document.name_lower
    desc_lower = document.description_lower
    body_lower = document.body_lower
    keywords_lower = document.keywords_lower

    # Calculate name scores (strongest signal)
    exact_name_match =
      if key_lower == context_lower or name_lower == context_lower,
        do: 100,
        else: 0

    partial_name_match =
      if exact_name_match == 0 and
           (String.contains?(key_lower, context_lower) or
              String.contains?(name_lower, context_lower)),
         do: 50,
         else: 0

    context_in_name_match =
      if String.contains?(context_lower, key_lower) or String.contains?(context_lower, name_lower),
        do: 30,
        else: 0

    name_word_matches =
      context_words
      |> Enum.count(fn word ->
        String.contains?(key_lower, word) or String.contains?(name_lower, word)
      end)

    name_score =
      exact_name_match
      |> max(partial_name_match)
      |> max(context_in_name_match)
      |> Kernel.+(name_word_matches * 40)

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
  defp source_priority_bonus(%{entry: %Entry{source: :project}}), do: 1000
  defp source_priority_bonus(_), do: 0

  defp extract_words(text) when is_binary(text) do
    text
    |> String.split(~r/[^\w]+/)
    |> Enum.filter(fn word -> String.length(word) > 2 end)
    |> Enum.uniq()
  end

  defp hydrate_from_lockfile(skills, scope) do
    case Lockfile.read(scope) do
      {:ok, records} when map_size(records) > 0 ->
        Map.new(skills, fn {key, entry} ->
          entry =
            case Map.fetch(records, key) do
              {:ok, record} -> Entry.with_provenance(entry, record)
              :error -> entry
            end

          {key, entry}
        end)

      _ ->
        skills
    end
  end

  defp add_entry(state, %Entry{source: :global} = entry) do
    state
    |> Map.put(:global_skills, Map.put(state.global_skills, entry.key, entry))
    |> rebuild_global_derived()
  end

  defp add_entry(state, %Entry{source: :project, path: path} = entry) do
    # Derive cwd from path
    cwd = path |> Path.dirname() |> Path.dirname() |> Path.dirname()
    project_skills = Map.get(state.project_skills, cwd, %{})
    project_skills = Map.put(project_skills, entry.key, entry)
    state = %{state | project_skills: Map.put(state.project_skills, cwd, project_skills)}
    rebuild_project_derived(state, cwd)
  end

  defp add_entry(state, entry) do
    # Default to global for other sources (URLs, etc.)
    state
    |> Map.put(:global_skills, Map.put(state.global_skills, entry.key, entry))
    |> rebuild_global_derived()
  end

  defp score_documents(documents, context, max_results, disabled) do
    context_lower = String.downcase(context)
    context_words = extract_words(context_lower)

    documents
    |> Enum.filter(fn document ->
      document.entry.enabled and document.entry.key not in disabled
    end)
    |> Enum.map(fn document ->
      score = calculate_relevance(document, context_lower, context_words)
      {document, score}
    end)
    |> Enum.filter(fn {_document, score} -> score > 0 end)
    |> Enum.map(fn {document, score} ->
      {document, score + source_priority_bonus(document)}
    end)
    |> Enum.sort_by(fn {document, score} -> {-score, document.entry.key || ""} end)
    |> Enum.take(normalize_max_results(max_results))
    |> Enum.map(fn {document, _score} -> document.entry end)
  end

  defp normalize_max_results(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_results(_value), do: 0

  defp rebuild_global_derived(state) do
    search = build_search_documents(state.global_skills)

    %{
      state
      | global_search: search,
        project_skills: %{},
        project_search: %{},
        project_identities: %{},
        project_identity_checked_at: %{}
    }
  end

  defp rebuild_project_derived(state, cwd) do
    project_skills = Map.get(state.project_skills, cwd, %{})

    # Global SKILL.md bodies have already been read into global_search. Only
    # new/overriding project entries need disk reads at this boundary.
    project_documents = build_search_documents(project_skills)
    search = Map.merge(state.global_search, project_documents)

    %{
      state
      | project_search: Map.put(state.project_search, cwd, search)
    }
  end

  defp build_search_documents(skills) do
    Map.new(skills, fn {key, entry} ->
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

      keywords =
        case entry.manifest do
          %{"keywords" => values} when is_list(values) -> values
          %{keywords: values} when is_list(values) -> values
          _ -> []
        end

      document = %{
        entry: entry,
        key_lower: String.downcase(entry.key || ""),
        name_lower: String.downcase(entry.name || entry.key || ""),
        description_lower: String.downcase(entry.description || ""),
        keywords_lower: Enum.map(keywords, &String.downcase/1),
        body_lower: body_lower
      }

      {key, document}
    end)
  end

  defp disabled_keys(cwd) do
    Config.load_config(cwd)
    |> Map.get("disabled", [])
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  # File discovery/status consumers call this outside the Registry process.
  # The filesystem walk therefore does not serialize unrelated lookups; only a
  # changed identity asks the GenServer to rebuild its cached entries/excerpts.
  defp ensure_current(cwd) do
    now = monotonic_ms()

    case GenServer.call(__MODULE__, {:reserve_identity_check, cwd, now}) do
      {false, false} ->
        :ok

      {check_global?, check_project?} ->
        {global_identity, project_identity} =
          cache_identity(cwd, check_global?, check_project?)

        GenServer.call(
          __MODULE__,
          {:ensure_current, cwd, global_identity, project_identity}
        )
    end
  end

  defp identity_check_due?(nil, _now), do: true

  defp identity_check_due?(last_checked_at, now),
    do: now - last_checked_at >= @identity_check_interval_ms

  defp maybe_reload_global(%{global_identity: identity} = state, identity), do: state
  defp maybe_reload_global(state, nil), do: state

  defp maybe_reload_global(state, identity) do
    %{load_global_skills(state) | global_identity: identity}
  end

  defp maybe_reload_project(state, _cwd, nil), do: state

  defp maybe_reload_project(state, cwd, identity) when is_binary(cwd) do
    if Map.get(state.project_identities, cwd) == identity do
      state
    else
      state = load_project_skills(state, cwd)

      %{
        state
        | project_identities: Map.put(state.project_identities, cwd, identity)
      }
    end
  end

  defp maybe_reload_project(state, _cwd, _identity), do: state

  defp cache_identity(cwd) do
    global = scope_identity(Config.global_skills_dirs(), Lockfile.path(:global))

    project =
      if is_binary(cwd) do
        scope_identity(Config.project_skills_dirs(cwd), Lockfile.path({:project, cwd}))
      end

    {global, project}
  end

  defp cache_identity(cwd, check_global?, check_project?) do
    global =
      if check_global?, do: scope_identity(Config.global_skills_dirs(), Lockfile.path(:global))

    project =
      if check_project? and is_binary(cwd) do
        scope_identity(Config.project_skills_dirs(cwd), Lockfile.path({:project, cwd}))
      end

    {global, project}
  end

  defp scope_identity(dirs, lockfile) do
    files =
      dirs
      |> Enum.flat_map(&skill_file_identities/1)
      |> Enum.sort()

    {dirs, files, file_identity(lockfile)}
  end

  defp skill_file_identities(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          skill_file = Path.join([dir, name, "SKILL.md"])

          if File.regular?(skill_file) do
            [{skill_file, file_identity(skill_file)}]
          else
            []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp file_identity(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      digest = :crypto.hash(:sha256, content)

      {:ok, stat.type, stat.size, stat.mtime, stat.ctime, stat.mode, stat.inode, digest}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
