defmodule LemonSkills.Registry do
  @moduledoc """
  GenServer for caching and managing skill entries.

  The registry maintains an in-memory cache of all available skills,
  loading them from disk on startup and providing fast lookups.

  ## Architecture

  Skills are loaded from `Config.global_skills_dirs/0` and
  `Config.project_skills_dirs/1`. These include Lemon, harness, OMP, Claude,
  Codex and GitHub SKILL.md bundles, one directory level below each skill root.

  Project skills override global skills with the same directory key. Within a
  scope, the first configured directory wins; ancestors are closest-first.
  Display names do not change a skill's key.

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

  alias LemonSkills.{Bundle, Entry, Manifest, Config, Discovery, Lockfile, TrustPolicy}
  alias LemonSkills.Audit.BundleAudit
  alias LemonSkills.Audit.State, as: AuditState
  alias LemonSkills.Sources.Builtin

  require Logger

  @identity_check_interval_ms 50

  @type state :: %{
          global_skills: %{String.t() => Entry.t()},
          project_skills: %{String.t() => %{String.t() => Entry.t()}},
          global_search: map(),
          project_search: map(),
          global_identity: term(),
          project_identities: %{String.t() => term()},
          global_identity_checked_at: integer() | nil,
          project_identity_checked_at: %{String.t() => integer() | nil},
          auto_audited: MapSet.t()
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
      project_identity_checked_at: %{},
      auto_audited: MapSet.new()
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

  # One-time upgrade path for unchanged skills installed into the agent
  # directory before the v2 hash format (see `upgrade_candidate/3`):
  # a supervised task runs the static install audit (lint + engine, no LLM
  # reviewer) on the live bytes. A pass records a grant exactly as an install
  # would; warn and block verdicts authorize nothing. Each `{key, hash}` is
  # attempted once per registry lifetime, and bytes that already carry an
  # audit record are never queued, so verdicts that do not authorize cannot
  # loop.
  @impl true
  def handle_info({:auto_audit, candidates}, state) do
    pending = Enum.reject(candidates, &MapSet.member?(state.auto_audited, auto_audit_id(&1)))

    cond do
      pending == [] ->
        {:noreply, state}

      is_nil(Process.whereis(LemonSkills.TaskSupervisor)) ->
        Process.send_after(self(), {:auto_audit, pending}, 100)
        {:noreply, state}

      true ->
        {:ok, _pid} =
          Task.Supervisor.start_child(LemonSkills.TaskSupervisor, fn ->
            Enum.each(pending, &static_audit/1)
            GenServer.cast(__MODULE__, :auto_audit_done)
          end)

        attempted = Enum.reduce(pending, state.auto_audited, &MapSet.put(&2, auto_audit_id(&1)))
        {:noreply, %{state | auto_audited: attempted}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:auto_audit_done, state) do
    {global_identity, _project_identity} = cache_identity(nil)

    {:noreply,
     %{
       load_global_skills(state)
       | global_identity: global_identity,
         global_identity_checked_at: monotonic_ms()
     }}
  end

  defp auto_audit_id(%{key: key, hash: hash}), do: {key, hash}

  # The audit is bound to the hash found eligible: if the bundle changed since,
  # nothing is audited, recorded or granted.
  defp static_audit(%{key: key, path: path, hash: hash}) do
    case BundleAudit.audit(path, :global, key, llm: [enabled: false], expected_hash: hash) do
      {:ok, record} ->
        Logger.info(
          "[Registry] upgrade audit of global skill '#{key}': #{record["final_verdict"]}"
        )

      {:error, reason} ->
        Logger.warning(
          "[Registry] upgrade audit of global skill '#{key}' failed: #{inspect(reason)}"
        )
    end
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

    # Hydrate provenance from the global lockfile where records are present,
    # then bind each entry to its operator-side authorization.
    hydrated = hydrate_from_lockfile(skills, :global)
    records = audit_records(:global)
    skills = authorize_entries(hydrated, records, :global)
    queue_upgrade_audits(hydrated, skills, records)

    rebuild_global_derived(%{state | global_skills: skills})
  end

  defp load_project_skills(state, cwd) when is_binary(cwd) do
    # Load roots in precedence order, including ancestor compatibility paths.
    skills =
      Config.project_skills_dirs(cwd)
      |> Enum.reduce(%{}, fn dir, acc ->
        dir_skills = load_skills_from_dir(dir, :project)

        # Keep first-seen entries so directory order controls precedence.
        # Project .lemon/skill has highest precedence, then closest ancestor.
        Map.merge(acc, dir_skills, fn _key, existing, _incoming -> existing end)
      end)

    # Hydrate provenance from the project lockfile where records are present,
    # then bind each entry to its operator-side authorization.
    skills =
      skills
      |> hydrate_from_lockfile({:project, cwd})
      |> authorize_entries(audit_records({:project, cwd}), {:project, cwd})

    project_skills = Map.put(state.project_skills, cwd, skills)
    state = %{state | project_skills: project_skills}
    rebuild_project_derived(state, cwd)
  end

  defp load_skills_from_dir(dir, source) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.filter(fn name ->
        path = Path.join(dir, name)

        not String.starts_with?(name, ".") and linkable_skill_dir?(path, source) and
          File.exists?(Path.join(path, "SKILL.md"))
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

  # Project skill roots are repository content: a skill dir there must be a
  # real directory, never a link out of the repository. Global roots are
  # user-owned, so a linked skill dir there is allowed.
  defp linkable_skill_dir?(path, :project),
    do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  defp linkable_skill_dir?(path, _source), do: File.dir?(path)

  defp load_skill_entry(path, source) do
    entry = Entry.new(path, source: source)

    case Entry.content(entry) do
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

  # Lockfile provenance is descriptive and, for projects, repository-controlled:
  # every record is reconciled against what its source can actually produce.
  defp hydrate_from_lockfile(skills, scope) do
    case Lockfile.read(scope) do
      {:ok, records} when map_size(records) > 0 ->
        Map.new(skills, fn {key, entry} ->
          entry =
            case Map.fetch(records, key) do
              {:ok, record} when is_map(record) ->
                entry
                |> Entry.with_provenance(record)
                |> TrustPolicy.reconcile_provenance(scope)

              _ ->
                entry
            end

          {key, entry}
        end)

      _ ->
        skills
    end
  end

  # The authorization of record is operator-side (`LemonSkills.Audit.State`),
  # never lockfile provenance. An entry is authorized only when a grant (or a
  # byte-identical builtin) matches its live bundle hash; anything else is
  # pending (or the verdict an audit of these exact bytes reached) and
  # `Status.loadable?/2` refuses it.
  defp authorize_entries(skills, records, scope) do
    Map.new(skills, fn {key, entry} -> {key, authorize_entry(entry, records, scope)} end)
  end

  defp audit_records(scope) do
    case AuditState.read(scope) do
      {:ok, records} -> records
      {:error, _} -> %{}
    end
  end

  # Only skills installed into the agent directory's own skill root, whose
  # operator-side global lockfile records a completed install (`pass`, `warn`
  # or `overridden`), qualify; pending imports, hand-placed directories,
  # other global roots and every project skill still need `lemon skill audit`.
  defp queue_upgrade_audits(hydrated, authorized, records) do
    root = Path.expand(Config.global_skills_dir())

    candidates =
      Enum.flat_map(authorized, fn
        {key, %Entry{authorized_hash: nil}} ->
          upgrade_candidate(Map.fetch!(hydrated, key), root, records)

        _authorized ->
          []
      end)

    if candidates != [], do: send(self(), {:auto_audit, candidates})
    :ok
  end

  # One-time upgrade only: the lockfile's `bundle_hash` must be the pre-v2
  # hash of exactly the live bytes, i.e. the bundle is unchanged since an
  # install recorded before the v2 hash format. Records with a v2 hash, edits
  # after install and records without a hash need `lemon skill audit`.
  defp upgrade_candidate(%Entry{key: key, audit_status: status} = entry, root, records)
       when status in [:pass, :warn, :overridden] and is_binary(entry.bundle_hash) do
    with true <- Path.dirname(Path.expand(entry.path)) == root,
         {:ok, scan} <- Bundle.scan(entry.path),
         true <- Bundle.legacy_hash(scan) == entry.bundle_hash,
         hash = Bundle.hash(scan),
         false <- match?(%{"bundle_hash" => ^hash}, Map.get(records, "skill:#{key}")) do
      [%{key: key, path: entry.path, hash: hash}]
    else
      _ -> []
    end
  end

  defp upgrade_candidate(_entry, _root, _records), do: []

  defp authorize_entry(%Entry{} = entry, records, scope) do
    live_hash = Entry.compute_bundle_hash(entry)

    cond do
      is_nil(live_hash) ->
        %{entry | authorized_hash: nil, audit_status: unauthorized_status(entry, records, nil)}

      scope == :global and Builtin.verified_install?(entry) ->
        %{entry | authorized_hash: live_hash}

      status = AuditState.grant_status(records, entry.key, live_hash) ->
        %{entry | authorized_hash: live_hash, audit_status: status}

      true ->
        %{
          entry
          | authorized_hash: nil,
            audit_status: unauthorized_status(entry, records, live_hash)
        }
    end
  end

  defp unauthorized_status(entry, records, live_hash) do
    case Map.get(records, "skill:#{entry.key}") do
      %{"bundle_hash" => ^live_hash, "final_verdict" => verdict}
      when is_binary(live_hash) and verdict in ["warn", "block"] ->
        String.to_existing_atom(verdict)

      _ ->
        if entry.audit_status == :block, do: :block, else: :pending
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
    global = scope_identity(Config.global_skills_dirs(), metadata_files(:global))

    project =
      if is_binary(cwd) do
        scope_identity(Config.project_skills_dirs(cwd), metadata_files({:project, cwd}))
      end

    {global, project}
  end

  defp cache_identity(cwd, check_global?, check_project?) do
    global =
      if check_global?, do: scope_identity(Config.global_skills_dirs(), metadata_files(:global))

    project =
      if check_project? and is_binary(cwd) do
        scope_identity(Config.project_skills_dirs(cwd), metadata_files({:project, cwd}))
      end

    {global, project}
  end

  # Provenance and authorization changes both re-hydrate the scope.
  defp metadata_files(scope), do: [Lockfile.path(scope), AuditState.path(scope)]

  defp scope_identity(dirs, metadata_files) do
    files =
      dirs
      |> Enum.flat_map(&skill_file_identities/1)
      |> Enum.sort()

    {dirs, files, Enum.map(metadata_files, &file_identity/1)}
  end

  defp skill_file_identities(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reject(&String.starts_with?(&1, "."))
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
