defmodule Mix.Tasks.Lemon.Skill do
  @moduledoc """
  Manage Lemon skills from the command line.

  This task provides commands for discovering, installing, updating, and
  removing skills. It integrates with the online skill discovery system
  to find skills from GitHub and other sources.

  ## Commands

      mix lemon.skill list              # List installed skills
      mix lemon.skill browse            # Browse installed skills with activation state
      mix lemon.skill search <query>    # Search for skills (local + online)
      mix lemon.skill discover <query>  # Discover skills from GitHub
      mix lemon.skill install <source>  # Install a skill from URL or path
      mix lemon.skill update <key>      # Update an installed skill
      mix lemon.skill remove <key>      # Remove an installed skill
      mix lemon.skill inspect <key>     # Deep-inspect a skill (provenance, deps, hashes)
      mix lemon.skill check <key>       # Check skill readiness and detect drift
      mix lemon.skill info <key>        # Show skill details (alias for inspect)

  ## Examples

      # List all installed skills
      mix lemon.skill list

      # Browse with activation state
      mix lemon.skill browse
      mix lemon.skill browse --active
      mix lemon.skill browse --not-ready

      # Search for skills related to "web"
      mix lemon.skill search web

      # Install a skill from GitHub
      mix lemon.skill install https://github.com/user/lemon-skill-name

      # Install a skill locally (project-only)
      mix lemon.skill install /path/to/skill --local

      # Check a skill's readiness and detect local modifications
      mix lemon.skill check my-skill

      # Deep-inspect provenance, trust, deps, and hashes
      mix lemon.skill inspect my-skill

      # Update a skill (shows diff summary before updating)
      mix lemon.skill update my-skill

      # Remove a skill
      mix lemon.skill remove my-skill

  ## Global vs Local Installation

  By default, skills are installed globally in `~/.lemon/agent/skill/`.
  Use `--local` to install in the current project's `.lemon/skill/` directory.
  """

  use Mix.Task

  alias LemonSkills.{Registry, Installer, Entry, Manifest, SkillView}
  alias LemonSkills.Synthesis.{DraftStore, Pipeline}

  @impl true
  def run(args) do
    # Ensure the application is started
    Mix.Task.run("app.start")

    case args do
      ["list" | opts] ->
        list_skills(opts)

      ["browse" | opts] ->
        browse_skills(opts)

      ["search", query | opts] ->
        search_skills(query, opts)

      ["discover", query | opts] ->
        discover_skills(query, opts)

      ["install", source | opts] ->
        install_skill(source, opts)

      ["update", key | opts] ->
        update_skill(key, opts)

      ["remove", key | opts] ->
        remove_skill(key, opts)

      ["inspect", key | opts] ->
        inspect_skill(key, opts)

      ["check", key | opts] ->
        check_skill(key, opts)

      ["info", key | opts] ->
        inspect_skill(key, opts)

      ["draft" | draft_args] ->
        manage_drafts(draft_args)

      _ ->
        print_usage()
    end
  end

  # ============================================================================
  # List Command
  # ============================================================================

  defp list_skills(opts) do
    cwd = get_cwd(opts)
    global_only = "--global" in opts

    skills =
      if global_only do
        Registry.list(cwd: nil)
      else
        Registry.list(cwd: cwd)
      end

    if Enum.empty?(skills) do
      Mix.shell().info("No skills installed.")
      Mix.shell().info("\nUse 'mix lemon.skill search <query>' to find skills.")
    else
      print_skills_table(skills, cwd)
    end

    :ok
  end

  # ============================================================================
  # Browse Command
  # ============================================================================

  defp browse_skills(opts) do
    cwd = get_cwd(opts)

    filter =
      cond do
        "--active" in opts -> :active
        "--not-ready" in opts -> :not_ready
        "--all" in opts -> :all
        true -> :displayable
      end

    entries = Registry.list(cwd: cwd)

    views =
      entries
      |> Enum.map(&SkillView.from_entry(&1, cwd: cwd))
      |> filter_views(filter)

    if Enum.empty?(views) do
      Mix.shell().info("No skills found.")
      Mix.shell().info("\nUse 'mix lemon.skill browse --all' to include hidden skills.")
    else
      print_browse_table(views)
    end

    :ok
  end

  defp filter_views(views, :active), do: Enum.filter(views, &SkillView.active?/1)

  defp filter_views(views, :not_ready),
    do: Enum.filter(views, fn v -> v.activation_state == :not_ready end)

  defp filter_views(views, :displayable), do: Enum.filter(views, &SkillView.displayable?/1)
  defp filter_views(views, :all), do: views

  # ============================================================================
  # Search Command
  # ============================================================================

  defp search_skills(query, opts) do
    cwd = get_cwd(opts)
    max_local = get_int_opt(opts, "--max-local", 5)
    max_online = get_int_opt(opts, "--max-online", 5)
    no_online = "--no-online" in opts

    Mix.shell().info("Searching for '#{query}'...")

    results =
      Registry.search(query,
        cwd: cwd,
        max_local: max_local,
        max_online: max_online,
        include_online: not no_online
      )

    # Print local results
    if Enum.empty?(results.local) do
      Mix.shell().info("\nNo local skills found.")
    else
      Mix.shell().info("\n=== Local Skills ===")
      print_skills_table(results.local, cwd)
    end

    # Print online results
    if not no_online do
      if Enum.empty?(results.online) do
        Mix.shell().info("\nNo online skills found.")
      else
        Mix.shell().info("\n=== Online Skills (GitHub) ===")
        print_discovery_results(results.online)
      end
    end

    :ok
  end

  # ============================================================================
  # Discover Command
  # ============================================================================

  defp discover_skills(query, opts) do
    max_results = get_int_opt(opts, "--max", 10)

    Mix.shell().info("Discovering skills for '#{query}' from GitHub...")

    results = Registry.discover(query, max_results: max_results)

    if Enum.empty?(results) do
      Mix.shell().info("\nNo skills found on GitHub.")
      Mix.shell().info("Try a different search query or check your internet connection.")
    else
      Mix.shell().info("\n=== Discovered Skills ===")
      print_discovery_results(results)
    end

    :ok
  end

  # ============================================================================
  # Install Command
  # ============================================================================

  defp install_skill(source, opts) do
    global = not ("--local" in opts)
    force = "--force" in opts
    cwd = if global, do: nil, else: get_cwd(opts)

    scope = if global, do: "globally", else: "locally"
    Mix.shell().info("Installing skill from #{source} #{scope}...")

    case Installer.install(source, global: global, cwd: cwd, force: force) do
      {:ok, %Entry{} = entry} ->
        manifest = entry.manifest || %{}
        Mix.shell().info([:green, "✓", :reset, " Successfully installed '#{entry.key}'"])
        Mix.shell().info("  Path: #{entry.path}")
        Mix.shell().info("  Name: #{entry.name}")

        desc = manifest["description"] || entry.description || ""
        if desc != "", do: Mix.shell().info("  Description: #{desc}")

        if entry.trust_level do
          Mix.shell().info("  Trust: #{entry.trust_level}")
        end

      {:error, reason} ->
        Mix.shell().error([:red, "✗", :reset, " Installation failed: #{inspect(reason)}"])
        Mix.raise("Skill installation failed")
    end

    :ok
  end

  # ============================================================================
  # Update Command (richer)
  # ============================================================================

  defp update_skill(key, opts) do
    cwd = get_cwd(opts)

    # Pre-flight: surface update status before doing the work
    case Registry.get(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        print_update_preflight(entry)

      :error ->
        Mix.shell().error("Skill '#{key}' not found.")
        Mix.raise("Skill not found")
    end

    Mix.shell().info("Updating skill '#{key}'...")

    case Installer.update(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        Mix.shell().info([:green, "✓", :reset, " Successfully updated '#{entry.key}'"])
        Mix.shell().info("  Path: #{entry.path}")

        if entry.content_hash do
          Mix.shell().info("  Content hash: #{String.slice(entry.content_hash, 0, 12)}...")
        end

      {:error, reason} ->
        Mix.shell().error([:red, "✗", :reset, " Update failed: #{inspect(reason)}"])
        Mix.raise("Skill update failed")
    end

    :ok
  end

  defp print_update_preflight(%Entry{} = entry) do
    current_hash = Entry.compute_content_hash(entry)

    locally_modified =
      is_binary(entry.content_hash) and is_binary(current_hash) and
        current_hash != entry.content_hash

    update_available =
      is_binary(entry.upstream_hash) and is_binary(entry.content_hash) and
        entry.upstream_hash != entry.content_hash

    if locally_modified do
      Mix.shell().info(
        [:yellow, "⚠", :reset, " '#{entry.key}' has local modifications (content differs from install hash)"]
      )
    end

    if update_available do
      Mix.shell().info(
        [:cyan, "↑", :reset, " '#{entry.key}' has an upstream update available"]
      )
    end

    if not locally_modified and not update_available and entry.content_hash do
      Mix.shell().info("  '#{entry.key}' appears up-to-date; forcing re-fetch.")
    end
  end

  # ============================================================================
  # Remove Command
  # ============================================================================

  defp remove_skill(key, opts) do
    cwd = get_cwd(opts)
    force = "--force" in opts

    # Confirm removal unless --force
    unless force do
      Mix.shell().info("This will remove the skill '#{key}'.")
      answer = Mix.shell().prompt("Are you sure? [y/N] ")

      unless String.downcase(String.trim(answer)) == "y" do
        Mix.shell().info("Cancelled.")
        :ok
      end
    end

    Mix.shell().info("Removing skill '#{key}'...")

    case Installer.uninstall(key, cwd: cwd) do
      :ok ->
        Mix.shell().info([:green, "✓", :reset, " Successfully removed '#{key}'"])

      {:error, reason} ->
        Mix.shell().error([:red, "✗", :reset, " Removal failed: #{inspect(reason)}"])
        Mix.raise("Skill removal failed")
    end

    :ok
  end

  # ============================================================================
  # Inspect Command
  # ============================================================================

  defp inspect_skill(key, opts) do
    cwd = get_cwd(opts)

    case Registry.get(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        view = SkillView.from_entry(entry, cwd: cwd)
        print_inspect_output(entry, view)

      :error ->
        Mix.shell().error("Skill '#{key}' not found.")
        Mix.shell().info("\nUse 'mix lemon.skill list' to see installed skills.")
        Mix.shell().info("Use 'mix lemon.skill search #{key}' to find similar skills.")
        Mix.raise("Skill not found")
    end

    :ok
  end

  defp print_inspect_output(%Entry{} = entry, %SkillView{} = view) do
    manifest = entry.manifest || %{}
    refs = Manifest.references(manifest)
    env_vars = Manifest.required_environment_variables(manifest)
    bins = Manifest.required_bins(manifest)
    tools = Manifest.requires_tools(manifest)
    platforms = Manifest.platforms(manifest)

    IO.puts("\n=== Skill: #{entry.key} ===\n")

    IO.puts("Key:          #{entry.key}")
    IO.puts("Name:         #{entry.name}")
    IO.puts("Description:  #{entry.description}")
    IO.puts("Path:         #{entry.path}")
    IO.puts("Activation:   #{format_activation(view.activation_state)}")

    if platforms != ["any"] do
      IO.puts("Platforms:    #{Enum.join(platforms, ", ")}")
    end

    IO.puts("")
    IO.puts("--- Provenance ---")
    IO.puts("Source:       #{format_source(entry.source)}")
    IO.puts("Source kind:  #{entry.source_kind || "unknown"}")
    IO.puts("Source ID:    #{entry.source_id || "n/a"}")
    IO.puts("Trust level:  #{entry.trust_level || "unknown"}")
    IO.puts("Installed at: #{format_datetime(entry.installed_at)}")
    IO.puts("Updated at:   #{format_datetime(entry.updated_at)}")
    IO.puts("Audit status: #{entry.audit_status || "n/a"}")

    if entry.audit_findings != [] do
      IO.puts("Audit notes:  #{Enum.join(entry.audit_findings, "; ")}")
    end

    IO.puts("")
    IO.puts("--- Content Hashes ---")
    IO.puts("Install hash:  #{abbrev_hash(entry.content_hash)}")
    IO.puts("Upstream hash: #{abbrev_hash(entry.upstream_hash)}")

    current_hash = Entry.compute_content_hash(entry)
    IO.puts("Current hash:  #{abbrev_hash(current_hash)}")

    cond do
      is_nil(entry.content_hash) ->
        IO.puts("Drift:         (no baseline — installed without provenance)")

      current_hash != entry.content_hash ->
        IO.puts("Drift:         ⚠  locally modified since install")

      is_binary(entry.upstream_hash) and entry.upstream_hash != entry.content_hash ->
        IO.puts("Drift:         ↑  upstream update available")

      true ->
        IO.puts("Drift:         ✓  matches install hash")
    end

    if bins != [] or env_vars != [] or tools != [] do
      IO.puts("")
      IO.puts("--- Requirements ---")

      if bins != [] do
        status_list = Enum.map(bins, fn b ->
          ok = b not in view.missing_bins
          "#{if ok, do: "✓", else: "✗"} #{b}"
        end)
        IO.puts("Binaries:  #{Enum.join(status_list, ", ")}")
      end

      if env_vars != [] do
        status_list = Enum.map(env_vars, fn v ->
          ok = v not in view.missing_env_vars
          "#{if ok, do: "✓", else: "✗"} #{v}"
        end)
        IO.puts("Env vars:  #{Enum.join(status_list, ", ")}")
      end

      if tools != [] do
        status_list = Enum.map(tools, fn t ->
          ok = t not in view.missing_tools
          "#{if ok, do: "✓", else: "✗"} #{t}"
        end)
        IO.puts("Tools:     #{Enum.join(status_list, ", ")}")
      end
    end

    if refs != [] do
      IO.puts("")
      IO.puts("--- References ---")
      Enum.each(refs, fn ref ->
        case ref do
          %{"path" => path} -> IO.puts("  #{path}")
          path when is_binary(path) -> IO.puts("  #{path}")
          _ -> IO.puts("  #{inspect(ref)}")
        end
      end)
    end

    IO.puts("")
  end

  # ============================================================================
  # Check Command
  # ============================================================================

  defp check_skill(key, opts) do
    cwd = get_cwd(opts)

    case Registry.get(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        view = SkillView.from_entry(entry, cwd: cwd)
        current_hash = Entry.compute_content_hash(entry)

        locally_modified =
          is_binary(entry.content_hash) and is_binary(current_hash) and
            current_hash != entry.content_hash

        update_available =
          is_binary(entry.upstream_hash) and is_binary(entry.content_hash) and
            entry.upstream_hash != entry.content_hash

        print_check_output(entry, view, %{
          locally_modified: locally_modified,
          update_available: update_available,
          current_hash: current_hash
        })

      :error ->
        Mix.shell().error("Skill '#{key}' not found.")
        Mix.raise("Skill not found")
    end

    :ok
  end

  defp print_check_output(%Entry{} = entry, %SkillView{} = view, checks) do
    IO.puts("\n=== Check: #{entry.key} ===\n")

    # Activation state
    IO.puts("Activation:  #{format_activation(view.activation_state)}")

    # Missing requirements
    missing = SkillView.all_missing(view)

    if missing == [] do
      IO.puts("Readiness:   ✓ all requirements met")
    else
      IO.puts("Readiness:   ✗ missing: #{Enum.join(missing, ", ")}")
    end

    # Local modification check
    if checks.locally_modified do
      IO.puts("Local drift: ⚠  content differs from install hash (locally modified)")
    else
      IO.puts("Local drift: ✓ content matches install hash")
    end

    # Upstream check
    if checks.update_available do
      IO.puts("Upstream:    ↑ update available (upstream hash differs from install hash)")
    else
      IO.puts("Upstream:    ✓ up-to-date")
    end

    # Verdict
    IO.puts("")

    cond do
      view.activation_state == :active and not checks.locally_modified ->
        IO.puts("✓ Skill is ready to use.")

      view.activation_state == :active ->
        IO.puts("✓ Skill is active (with local modifications).")

      view.activation_state == :not_ready ->
        IO.puts("✗ Skill is not ready. Run 'mix lemon.skill inspect #{entry.key}' for details.")

      true ->
        IO.puts("⚠ Skill state: #{view.activation_state}.")
    end

    IO.puts("")
  end

  # ============================================================================
  # Output Helpers
  # ============================================================================

  defp print_skills_table(skills, _cwd) do
    IO.puts(
      "\n#{String.pad_trailing("KEY", 20)} #{String.pad_trailing("STATUS", 10)} #{String.pad_trailing("SOURCE", 10)} DESCRIPTION"
    )

    IO.puts(String.duplicate("-", 80))

    Enum.each(skills, fn %Entry{} = entry ->
      status = if entry.enabled, do: "enabled", else: "disabled"
      source = format_source_short(entry.source)
      desc = get_description(entry)
      desc = if String.length(desc) > 35, do: String.slice(desc, 0, 32) <> "...", else: desc

      IO.puts(
        "#{String.pad_trailing(entry.key, 20)} #{String.pad_trailing(status, 10)} #{String.pad_trailing(source, 10)} #{desc}"
      )
    end)

    IO.puts("\n#{length(skills)} skill(s) found.")
  end

  defp print_browse_table(views) do
    IO.puts(
      "\n#{String.pad_trailing("KEY", 20)} #{String.pad_trailing("ACTIVATION", 20)} #{String.pad_trailing("TRUST", 12)} DESCRIPTION"
    )

    IO.puts(String.duplicate("-", 90))

    Enum.each(views, fn %SkillView{} = view ->
      activation = format_activation_short(view.activation_state)
      trust = if view.trust_level, do: to_string(view.trust_level), else: "unknown"
      desc = view.description
      desc = if String.length(desc) > 35, do: String.slice(desc, 0, 32) <> "...", else: desc

      IO.puts(
        "#{String.pad_trailing(view.key, 20)} #{String.pad_trailing(activation, 20)} #{String.pad_trailing(trust, 12)} #{desc}"
      )
    end)

    IO.puts("\n#{length(views)} skill(s).")
  end

  defp print_discovery_results(results) do
    IO.puts(
      "\n#{String.pad_trailing("NAME", 25)} #{String.pad_trailing("SOURCE", 10)} VALIDATED DESCRIPTION"
    )

    IO.puts(String.duplicate("-", 80))

    Enum.each(results, fn %{entry: entry, source: source, validated: validated, url: url} ->
      name = entry.key
      source_str = Atom.to_string(source)
      validated_str = if validated, do: "✓", else: "✗"
      manifest = entry.manifest || %{}
      desc = manifest["description"] || entry.description || ""
      desc = if String.length(desc) > 30, do: String.slice(desc, 0, 27) <> "...", else: desc

      IO.puts(
        "#{String.pad_trailing(name, 25)} #{String.pad_trailing(source_str, 10)} #{validated_str}         #{desc}"
      )

      IO.puts("  URL: #{url}")
    end)

    IO.puts("\n#{length(results)} skill(s) found.")
    IO.puts("\nInstall with: mix lemon.skill install <URL>")
  end

  # ============================================================================
  # Draft Commands
  # ============================================================================

  defp manage_drafts(["list" | opts]) do
    global = not ("--local" in opts)
    cwd = unless global, do: get_cwd(opts)

    {:ok, drafts} = DraftStore.list(global: global, cwd: cwd)

    if Enum.empty?(drafts) do
      Mix.shell().info("No skill drafts found.")
      Mix.shell().info("\nRun 'mix lemon.skill draft generate' to synthesize drafts.")
    else
      Mix.shell().info("\n#{String.pad_trailing("KEY", 30)} #{String.pad_trailing("CREATED", 24)} STATUS")
      Mix.shell().info(String.duplicate("-", 70))

      Enum.each(drafts, fn draft ->
        created = draft.created_at || "unknown"
        status = if draft.has_skill_file, do: "ready", else: "missing SKILL.md"

        Mix.shell().info(
          "#{String.pad_trailing(draft.key, 30)} #{String.pad_trailing(created, 24)} #{status}"
        )
      end)

      Mix.shell().info("\n#{length(drafts)} draft(s).")
      Mix.shell().info("\nReview:  mix lemon.skill draft review <key>")
      Mix.shell().info("Publish: mix lemon.skill draft publish <key>")
    end
  end

  defp manage_drafts(["generate" | opts]) do
    agent_id = get_opt(opts, "--agent", System.get_env("LEMON_AGENT_ID") || "default")
    max_docs = get_int_opt(opts, "--max-docs", 50)
    global = not ("--local" in opts)
    cwd = unless global, do: get_cwd(opts)

    Mix.shell().info("Synthesizing skill drafts from agent '#{agent_id}' (last #{max_docs} runs)...")

    case Pipeline.run(:agent, agent_id, max_docs: max_docs, global: global, cwd: cwd) do
      {:ok, %{generated: gen, skipped: skipped, total_candidates: total}} ->
        Mix.shell().info(
          [:green, "✓", :reset,
           " #{length(gen)} draft(s) generated from #{total} candidate(s)"]
        )

        if skipped != [] do
          Mix.shell().info("  Skipped #{length(skipped)}: #{inspect(Keyword.keys(skipped))}")
        end

        if gen != [] do
          Mix.shell().info("\nReview with: mix lemon.skill draft review <key>")
        end

      {:error, :feature_disabled} ->
        Mix.shell().error("Skill synthesis is disabled.")
        Mix.shell().info("Enable with: features.skill_synthesis_drafts = \"default-on\"")
        Mix.raise("Feature disabled")

      {:error, reason} ->
        Mix.shell().error("Generation failed: #{inspect(reason)}")
        Mix.raise("Draft generation failed")
    end
  end

  defp manage_drafts(["review", key | opts]) do
    global = not ("--local" in opts)
    cwd = unless global, do: get_cwd(opts)

    case DraftStore.get(key, global: global, cwd: cwd) do
      {:ok, %{content: content, meta: meta}} ->
        created = Map.get(meta, "created_at", "unknown")
        source_id = Map.get(meta, "source_doc_id", "unknown")

        Mix.shell().info("\n=== Draft: #{key} ===")
        Mix.shell().info("Created:       #{created}")
        Mix.shell().info("Source doc:    #{source_id}")
        Mix.shell().info("\n--- SKILL.md content ---\n")
        Mix.shell().info(content)
        Mix.shell().info("\n--- End of content ---\n")
        Mix.shell().info("Publish: mix lemon.skill draft publish #{key}")
        Mix.shell().info("Delete:  mix lemon.skill draft delete #{key}")

      {:error, :not_found} ->
        Mix.shell().error("Draft '#{key}' not found.")
        Mix.raise("Draft not found")
    end
  end

  defp manage_drafts(["publish", key | opts]) do
    global = not ("--local" in opts)
    cwd = unless global, do: get_cwd(opts)
    force = "--force" in opts

    Mix.shell().info("Publishing draft '#{key}'...")

    case DraftStore.promote(key, global: global, cwd: cwd, force: force) do
      {:ok, %Entry{} = entry} ->
        Mix.shell().info([:green, "✓", :reset, " Published '#{entry.key}' as installed skill"])
        Mix.shell().info("  Path: #{entry.path}")

      {:error, reason} ->
        Mix.shell().error("Publish failed: #{inspect(reason)}")
        Mix.raise("Publish failed")
    end
  end

  defp manage_drafts(["delete", key | opts]) do
    global = not ("--local" in opts)
    cwd = unless global, do: get_cwd(opts)
    force = "--force" in opts

    unless force do
      answer = Mix.shell().prompt("Delete draft '#{key}'? [y/N] ")
      unless String.downcase(String.trim(answer)) == "y" do
        Mix.shell().info("Cancelled.")
        :ok
      end
    end

    case DraftStore.delete(key, global: global, cwd: cwd) do
      :ok ->
        Mix.shell().info([:green, "✓", :reset, " Deleted draft '#{key}'"])

      {:error, reason} ->
        Mix.shell().error("Delete failed: #{inspect(reason)}")
        Mix.raise("Delete failed")
    end
  end

  defp manage_drafts(_) do
    Mix.shell().info("""
    Manage synthesized skill drafts.

    Usage:
      mix lemon.skill draft list              # List all drafts
      mix lemon.skill draft generate          # Synthesize new drafts from run history
      mix lemon.skill draft review <key>      # Review a draft's content
      mix lemon.skill draft publish <key>     # Promote a draft to an installed skill
      mix lemon.skill draft delete <key>      # Delete a draft

    Options:
      --local                    Work with project-local drafts (default: global)
      --cwd=<path>               Project directory for --local
      --agent=<id>               Agent ID for generate (default: LEMON_AGENT_ID env)
      --max-docs=<n>             Max memory docs to consider for generate (default: 50)
      --force                    Overwrite existing draft / installed skill
    """)
  end

  defp get_opt(opts, flag, default) do
    case Enum.find(opts, &String.starts_with?(&1, "#{flag}=")) do
      nil -> default
      opt -> String.replace_prefix(opt, "#{flag}=", "")
    end
  end

  defp print_usage do
    Mix.shell().info(@moduledoc)
  end

  # ============================================================================
  # Formatting Helpers
  # ============================================================================

  defp format_activation(:active), do: "active"
  defp format_activation(:not_ready), do: "not_ready"
  defp format_activation(:hidden), do: "hidden"
  defp format_activation(:platform_incompatible), do: "platform_incompatible"
  defp format_activation(:blocked), do: "blocked"
  defp format_activation(other), do: inspect(other)

  defp format_activation_short(:active), do: "✓ active"
  defp format_activation_short(:not_ready), do: "✗ not_ready"
  defp format_activation_short(:hidden), do: "~ hidden"
  defp format_activation_short(:platform_incompatible), do: "~ incompatible"
  defp format_activation_short(:blocked), do: "✗ blocked"
  defp format_activation_short(other), do: inspect(other)

  defp format_source(:global), do: "Global (~/.lemon/agent/skill)"
  defp format_source(:project), do: "Project (.lemon/skill)"
  defp format_source(url) when is_binary(url), do: url
  defp format_source(other), do: inspect(other)

  defp format_source_short(:global), do: "global"
  defp format_source_short(:project), do: "project"
  defp format_source_short(url) when is_binary(url), do: "remote"
  defp format_source_short(_), do: "unknown"

  defp format_datetime(nil), do: "n/a"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_string(dt)

  defp abbrev_hash(nil), do: "n/a"
  defp abbrev_hash(hash), do: "#{String.slice(hash, 0, 12)}..."

  defp get_description(%Entry{description: description})
       when is_binary(description) and description != "" do
    description
  end

  defp get_description(%Entry{manifest: nil}), do: ""

  defp get_description(%Entry{manifest: manifest}) when is_map(manifest) do
    manifest["description"] || manifest[:description] || ""
  end

  # ============================================================================
  # Option Helpers
  # ============================================================================

  defp get_cwd(opts) do
    case Enum.find(opts, &String.starts_with?(&1, "--cwd=")) do
      nil -> File.cwd!()
      opt -> String.replace_prefix(opt, "--cwd=", "")
    end
  end

  defp get_int_opt(opts, flag, default) do
    case Enum.find(opts, &String.starts_with?(&1, "#{flag}=")) do
      nil ->
        default

      opt ->
        opt
        |> String.replace_prefix("#{flag}=", "")
        |> String.to_integer()
    end
  end
end
