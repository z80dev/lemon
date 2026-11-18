defmodule LemonSkills.CLI do
  @moduledoc """
  Manage Lemon skills from the command line.

  This task provides commands for discovering, installing, updating, and
  removing skills. It integrates with the online skill discovery system
  to find skills from GitHub and other sources.

  ## Commands

      lemon skill list              # List installed skills
      lemon skill browse            # Browse installed skills with activation state
      lemon skill search <query>    # Search for skills (local + online)
      lemon skill discover <query>  # Discover skills from GitHub
      lemon skill hermes [query]    # Browse the live official Hermes catalog
      lemon skill install <source>  # Install a skill from URL or path
      lemon skill update <key>      # Update an installed skill
      lemon skill remove <key>      # Remove an installed skill
      lemon skill audit <key>       # Re-audit a skill and authorize its exact bytes for loading
      lemon skill inspect <key>     # Deep-inspect a skill (provenance, deps, hashes)
      lemon skill check <key>       # Check skill readiness and detect drift
      lemon skill info <key>        # Show skill details (alias for inspect)
      lemon skill curator status    # Show learned-skill curation candidates
      lemon skill curator run       # Apply conservative lifecycle transitions

  ## Examples

      # List all installed skills
      lemon skill list

      # Browse with activation state
      lemon skill browse
      lemon skill browse --active
      lemon skill browse --not-ready

      # Search for skills related to "web"
      lemon skill search web

      # Install a skill from GitHub
      lemon skill install https://github.com/user/lemon-skill-name

      # Install a skill locally (project-only)
      lemon skill install /path/to/skill --local

      # Check a skill's readiness and detect local modifications
      lemon skill check my-skill

      # Deep-inspect provenance, trust, deps, and hashes
      lemon skill inspect my-skill

      # Update a skill (shows diff summary before updating)
      lemon skill update my-skill

      # Remove a skill
      lemon skill remove my-skill

  ## Global vs Local Installation

  By default, skills are installed globally in `~/.lemon/agent/skill/`.
  Use `--local` to install in the current project's `.lemon/skill/` directory.
  """

  alias LemonSkills.{Registry, Installer, Entry, Manifest, SkillView, Curator}
  alias LemonSkills.Audit.{BundleAudit, State}
  alias LemonSkills.Sources.Hermes
  alias LemonSkills.Synthesis.{DraftStore, Pipeline}

  def run(args) do
    LemonCore.CLI.start!(:lemon_skills)

    case args do
      ["list" | opts] ->
        list_skills(opts)

      ["browse" | opts] ->
        browse_skills(opts)

      ["search", query | opts] ->
        search_skills(query, opts)

      ["discover", query | opts] ->
        discover_skills(query, opts)

      ["hermes" | args] ->
        browse_hermes(args)

      ["install", source | opts] ->
        install_skill(source, opts)

      ["update", key | opts] ->
        update_skill(key, opts)

      ["remove", key | opts] ->
        remove_skill(key, opts)

      ["inspect", key | opts] ->
        inspect_skill(key, opts)

      ["audit", key | opts] ->
        audit_skill(key, opts)

      ["check", key | opts] ->
        check_skill(key, opts)

      ["info", key | opts] ->
        inspect_skill(key, opts)

      ["draft" | draft_args] ->
        manage_drafts(draft_args)

      ["curator" | curator_args] ->
        manage_curator(curator_args)

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
      LemonCore.CLI.info("No skills installed.")
      LemonCore.CLI.info("\nUse 'lemon skill search <query>' to find skills.")
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
      LemonCore.CLI.info("No skills found.")
      LemonCore.CLI.info("\nUse 'lemon skill browse --all' to include hidden skills.")
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

    LemonCore.CLI.info("Searching for '#{query}'...")

    results =
      Registry.search(query,
        cwd: cwd,
        max_local: max_local,
        max_online: max_online,
        include_online: not no_online
      )

    # Print local results
    if Enum.empty?(results.local) do
      LemonCore.CLI.info("\nNo local skills found.")
    else
      LemonCore.CLI.info("\n=== Local Skills ===")
      print_skills_table(results.local, cwd)
    end

    # Print online results
    if not no_online do
      if Enum.empty?(results.online) do
        LemonCore.CLI.info("\nNo online skills found.")
      else
        LemonCore.CLI.info("\n=== Online Skills (GitHub) ===")
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

    LemonCore.CLI.info("Discovering skills for '#{query}' from GitHub...")

    results = Registry.discover(query, max_results: max_results)

    if Enum.empty?(results) do
      LemonCore.CLI.info("\nNo skills found on GitHub.")
      LemonCore.CLI.info("Try a different search query or check your internet connection.")
    else
      LemonCore.CLI.info("\n=== Discovered Skills ===")
      print_discovery_results(results)
    end

    :ok
  end

  # ============================================================================
  # Hermes Catalog Command
  # ============================================================================

  defp browse_hermes(args) do
    {query_parts, opts} = Enum.split_with(args, &(not String.starts_with?(&1, "--")))

    catalog_opts =
      [query: Enum.join(query_parts, " "), details: "--details" in opts]
      |> maybe_catalog_opt(:category, get_opt(opts, "--category", nil))
      |> maybe_catalog_opt(:collection, get_opt(opts, "--collection", nil))

    LemonCore.CLI.info("Loading the live official Hermes skill catalog...")

    case Hermes.catalog(catalog_opts) do
      {:ok, entries} when entries == [] ->
        LemonCore.CLI.info("No matching Hermes skills.")

      {:ok, entries} ->
        IO.puts(
          "\n#{String.pad_trailing("ID", 55)} #{String.pad_trailing("CATEGORY", 22)} DESCRIPTION"
        )

        IO.puts(String.duplicate("-", 110))

        Enum.each(entries, fn entry ->
          description = if entry.description == "", do: "(use --details)", else: entry.description

          IO.puts(
            "#{String.pad_trailing(entry.id, 55)} #{String.pad_trailing(entry.category, 22)} #{description}"
          )
        end)

        IO.puts("\n#{length(entries)} official Hermes skill(s).")
        IO.puts("Install one with: lemon skill install <ID>")

      {:error, reason} ->
        LemonCore.CLI.error("Unable to load Hermes catalog: #{inspect(reason)}")
        LemonCore.CLI.fail!("Hermes catalog lookup failed")
    end

    :ok
  end

  defp maybe_catalog_opt(opts, _key, nil), do: opts
  defp maybe_catalog_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================================
  # Install Command
  # ============================================================================

  defp install_skill(source, opts) do
    global = "--local" not in opts
    force = "--force" in opts
    cwd = if global, do: nil, else: get_cwd(opts)

    scope = if global, do: "globally", else: "locally"
    LemonCore.CLI.info("Installing skill from #{source} #{scope}...")

    case Installer.install(source, global: global, cwd: cwd, force: force) do
      {:ok, %Entry{} = entry} ->
        manifest = entry.manifest || %{}
        LemonCore.CLI.info([:green, "✓", :reset, " Successfully installed '#{entry.key}'"])
        LemonCore.CLI.info("  Path: #{entry.path}")
        LemonCore.CLI.info("  Name: #{entry.name}")

        desc = manifest["description"] || entry.description || ""
        if desc != "", do: LemonCore.CLI.info("  Description: #{desc}")

        if entry.trust_level do
          LemonCore.CLI.info("  Trust: #{entry.trust_level}")
        end

      {:error, reason} ->
        LemonCore.CLI.error([:red, "✗", :reset, " Installation failed: #{inspect(reason)}"])
        LemonCore.CLI.fail!("Skill installation failed")
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
        LemonCore.CLI.error("Skill '#{key}' not found.")
        LemonCore.CLI.fail!("Skill not found")
    end

    LemonCore.CLI.info("Updating skill '#{key}'...")

    case Installer.update(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        LemonCore.CLI.info([:green, "✓", :reset, " Successfully updated '#{entry.key}'"])
        LemonCore.CLI.info("  Path: #{entry.path}")

        if entry.content_hash do
          LemonCore.CLI.info("  Content hash: #{String.slice(entry.content_hash, 0, 12)}...")
        end

      {:error, reason} ->
        LemonCore.CLI.error([:red, "✗", :reset, " Update failed: #{inspect(reason)}"])
        LemonCore.CLI.fail!("Skill update failed")
    end

    :ok
  end

  defp print_update_preflight(%Entry{} = entry) do
    current_hash = current_install_hash(entry)

    locally_modified =
      is_binary(stored_install_hash(entry)) and is_binary(current_hash) and
        current_hash != stored_install_hash(entry)

    update_available =
      is_binary(entry.upstream_hash) and is_binary(stored_install_hash(entry)) and
        entry.upstream_hash != stored_install_hash(entry)

    if locally_modified do
      LemonCore.CLI.info([
        :yellow,
        "⚠",
        :reset,
        " '#{entry.key}' has local modifications (content differs from install hash)"
      ])
    end

    if update_available do
      LemonCore.CLI.info([:cyan, "↑", :reset, " '#{entry.key}' has an upstream update available"])
    end

    if not locally_modified and not update_available and stored_install_hash(entry) do
      LemonCore.CLI.info("  '#{entry.key}' appears up-to-date; forcing re-fetch.")
    end
  end

  # ============================================================================
  # Audit Command
  # ============================================================================

  # Re-audits the live bundle and records an operator-side load authorization
  # for exactly those bytes: a pass authorizes on its own, a warning only with
  # `--approve`. A block is never authorized here; activating blocked content
  # needs the installer's exact-bundle security override.
  defp audit_skill(key, opts) do
    cwd = get_cwd(opts)

    case Registry.get(key, cwd: cwd) do
      {:ok, entry} ->
        scope = if entry.source == :project, do: {:project, cwd}, else: :global
        LemonCore.CLI.info("Auditing skill '#{key}'...")

        result =
          with {:ok, record} <- BundleAudit.audit(entry.path, scope, key, force: true) do
            authorize_audited(scope, key, record, "--approve" in opts)
          end

        LemonSkills.refresh(cwd: cwd)
        report_audit(key, result)

      :error ->
        LemonCore.CLI.fail!("Skill not found: #{key}")
    end

    :ok
  end

  defp authorize_audited(_scope, _key, %{"final_verdict" => "pass"} = record, _approve),
    do: {:ok, :pass, record}

  defp authorize_audited(scope, key, %{"final_verdict" => "warn"} = record, true) do
    with :ok <- State.authorize(scope, key, record["bundle_hash"], :warn),
         do: {:ok, :warn, record}
  end

  defp authorize_audited(_scope, _key, record, _approve),
    do: {:refused, BundleAudit.audit_status(record), record}

  defp report_audit(key, {:ok, status, record}) do
    LemonCore.CLI.info([
      :green,
      "✓",
      :reset,
      " '#{key}' authorized (#{status}) for bundle #{abbrev_hash(record["bundle_hash"])}"
    ])

    print_audit_findings(record)
  end

  defp report_audit(key, {:refused, status, record}) do
    LemonCore.CLI.error([:red, "✗", :reset, " '#{key}' not authorized: audit verdict #{status}"])
    print_audit_findings(record)

    if status == :warn do
      LemonCore.CLI.info("Re-run with --approve to accept these warnings for this exact bundle.")
    end

    LemonCore.CLI.fail!("Skill audit did not authorize '#{key}'")
  end

  defp report_audit(key, {:error, reason}) do
    LemonCore.CLI.fail!("Audit of '#{key}' failed: #{inspect(reason)}")
  end

  defp print_audit_findings(record) do
    Enum.each(BundleAudit.audit_findings(record), &LemonCore.CLI.info("  - " <> &1))
  end

  # ============================================================================
  # Remove Command
  # ============================================================================

  defp remove_skill(key, opts) do
    cwd = get_cwd(opts)
    force = "--force" in opts

    confirmed =
      if force do
        true
      else
        LemonCore.CLI.info("This will remove the skill '#{key}'.")
        answer = LemonCore.CLI.prompt("Are you sure? [y/N] ")
        String.downcase(String.trim(answer)) == "y"
      end

    unless confirmed do
      LemonCore.CLI.info("Cancelled.")
    else
      LemonCore.CLI.info("Removing skill '#{key}'...")

      case Installer.uninstall(key, cwd: cwd) do
        :ok ->
          LemonCore.CLI.info([:green, "✓", :reset, " Successfully removed '#{key}'"])

        {:error, reason} ->
          LemonCore.CLI.error([:red, "✗", :reset, " Removal failed: #{inspect(reason)}"])
          LemonCore.CLI.fail!("Skill removal failed")
      end
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
        LemonCore.CLI.error("Skill '#{key}' not found.")
        LemonCore.CLI.info("\nUse 'lemon skill list' to see installed skills.")
        LemonCore.CLI.info("Use 'lemon skill search #{key}' to find similar skills.")
        LemonCore.CLI.fail!("Skill not found")
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
    IO.puts("Bundle hash:   #{abbrev_hash(entry.bundle_hash)}")
    IO.puts("Upstream hash: #{abbrev_hash(entry.upstream_hash)}")

    current_hash = current_install_hash(entry)
    IO.puts("Current hash:  #{abbrev_hash(current_hash)}")

    cond do
      is_nil(stored_install_hash(entry)) ->
        IO.puts("Drift:         (no baseline — installed without provenance)")

      current_hash != stored_install_hash(entry) ->
        IO.puts("Drift:         ⚠  locally modified since install")

      is_binary(entry.upstream_hash) and entry.upstream_hash != stored_install_hash(entry) ->
        IO.puts("Drift:         ↑  upstream update available")

      true ->
        IO.puts("Drift:         ✓  matches install hash")
    end

    if bins != [] or env_vars != [] or tools != [] do
      IO.puts("")
      IO.puts("--- Requirements ---")

      if bins != [] do
        status_list =
          Enum.map(bins, fn b ->
            ok = b not in view.missing_bins
            "#{if ok, do: "✓", else: "✗"} #{b}"
          end)

        IO.puts("Binaries:  #{Enum.join(status_list, ", ")}")
      end

      if env_vars != [] do
        status_list =
          Enum.map(env_vars, fn v ->
            ok = v not in view.missing_env_vars
            "#{if ok, do: "✓", else: "✗"} #{v}"
          end)

        IO.puts("Env vars:  #{Enum.join(status_list, ", ")}")
      end

      if tools != [] do
        status_list =
          Enum.map(tools, fn t ->
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
        current_hash = current_install_hash(entry)

        locally_modified =
          is_binary(stored_install_hash(entry)) and is_binary(current_hash) and
            current_hash != stored_install_hash(entry)

        update_available =
          is_binary(entry.upstream_hash) and is_binary(stored_install_hash(entry)) and
            entry.upstream_hash != stored_install_hash(entry)

        print_check_output(entry, view, %{
          locally_modified: locally_modified,
          update_available: update_available,
          current_hash: current_hash
        })

      :error ->
        LemonCore.CLI.error("Skill '#{key}' not found.")
        LemonCore.CLI.fail!("Skill not found")
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
      IO.puts("Upstream:    ↑ update available (upstream hash differs from installed baseline)")
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
        IO.puts("✗ Skill is not ready. Run 'lemon skill inspect #{entry.key}' for details.")

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
    IO.puts("\nInstall with: lemon skill install <URL>")
  end

  # ============================================================================
  # Draft Commands
  # ============================================================================

  defp manage_drafts(["list" | opts]) do
    global = "--local" not in opts
    cwd = unless global, do: get_cwd(opts)

    {:ok, drafts} = DraftStore.list(global: global, cwd: cwd)

    if Enum.empty?(drafts) do
      LemonCore.CLI.info("No skill drafts found.")
      LemonCore.CLI.info("\nRun 'lemon skill draft generate' to synthesize drafts.")
    else
      LemonCore.CLI.info(
        "\n#{String.pad_trailing("KEY", 30)} #{String.pad_trailing("CREATED", 24)} STATUS"
      )

      LemonCore.CLI.info(String.duplicate("-", 70))

      Enum.each(drafts, fn draft ->
        created = draft.created_at || "unknown"
        status = if draft.has_skill_file, do: "ready", else: "missing SKILL.md"

        LemonCore.CLI.info(
          "#{String.pad_trailing(draft.key, 30)} #{String.pad_trailing(created, 24)} #{status}"
        )
      end)

      LemonCore.CLI.info("\n#{length(drafts)} draft(s).")
      LemonCore.CLI.info("\nReview:  lemon skill draft review <key>")
      LemonCore.CLI.info("Publish: lemon skill draft publish <key>")
    end
  end

  defp manage_drafts(["generate" | opts]) do
    agent_id = get_opt(opts, "--agent", System.get_env("LEMON_AGENT_ID") || "default")
    max_docs = get_int_opt(opts, "--max-docs", 50)
    global = "--local" not in opts
    cwd = unless global, do: get_cwd(opts)

    LemonCore.CLI.info(
      "Synthesizing skill drafts from agent '#{agent_id}' (last #{max_docs} runs)..."
    )

    case Pipeline.run(:agent, agent_id, max_docs: max_docs, global: global, cwd: cwd) do
      {:ok, %{generated: gen, skipped: skipped, total_candidates: total}} ->
        LemonCore.CLI.info([
          :green,
          "✓",
          :reset,
          " #{length(gen)} draft(s) generated from #{total} candidate(s)"
        ])

        if skipped != [] do
          LemonCore.CLI.info("  Skipped #{length(skipped)}: #{inspect(Keyword.keys(skipped))}")
        end

        if gen != [] do
          LemonCore.CLI.info("\nReview with: lemon skill draft review <key>")
        end

      {:error, :feature_disabled} ->
        LemonCore.CLI.error(
          "Skill synthesis is disabled (features.skill_synthesis_drafts = \"off\")."
        )

        LemonCore.CLI.info("Re-enable with: features.skill_synthesis_drafts = \"default-on\"")
        LemonCore.CLI.fail!("Feature disabled")
    end
  end

  defp manage_drafts(["review", key | opts]) do
    global = "--local" not in opts
    cwd = unless global, do: get_cwd(opts)

    case DraftStore.get(key, global: global, cwd: cwd) do
      {:ok, %{content: content, meta: meta}} ->
        created = Map.get(meta, "created_at", "unknown")
        source_id = Map.get(meta, "source_doc_id", "unknown")

        LemonCore.CLI.info("\n=== Draft: #{key} ===")
        LemonCore.CLI.info("Created:       #{created}")
        LemonCore.CLI.info("Source doc:    #{source_id}")
        LemonCore.CLI.info("\n--- SKILL.md content ---\n")
        LemonCore.CLI.info(content)
        LemonCore.CLI.info("\n--- End of content ---\n")
        LemonCore.CLI.info("Publish: lemon skill draft publish #{key}")
        LemonCore.CLI.info("Delete:  lemon skill draft delete #{key}")

      {:error, :not_found} ->
        LemonCore.CLI.error("Draft '#{key}' not found.")
        LemonCore.CLI.fail!("Draft not found")
    end
  end

  defp manage_drafts(["publish", key | opts]) do
    global = "--local" not in opts
    cwd = unless global, do: get_cwd(opts)
    force = "--force" in opts

    LemonCore.CLI.info("Publishing draft '#{key}'...")

    case DraftStore.promote(key, global: global, cwd: cwd, force: force) do
      {:ok, %Entry{} = entry} ->
        LemonCore.CLI.info([:green, "✓", :reset, " Published '#{entry.key}' as installed skill"])
        LemonCore.CLI.info("  Path: #{entry.path}")

      {:error, reason} ->
        LemonCore.CLI.error("Publish failed: #{inspect(reason)}")
        LemonCore.CLI.fail!("Publish failed")
    end
  end

  defp manage_drafts(["delete", key | opts]) do
    global = "--local" not in opts
    cwd = unless global, do: get_cwd(opts)
    force = "--force" in opts

    unless force do
      answer = LemonCore.CLI.prompt("Delete draft '#{key}'? [y/N] ")

      unless String.downcase(String.trim(answer)) == "y" do
        LemonCore.CLI.info("Cancelled.")
        :ok
      end
    end

    case DraftStore.delete(key, global: global, cwd: cwd) do
      :ok ->
        LemonCore.CLI.info([:green, "✓", :reset, " Deleted draft '#{key}'"])

      {:error, reason} ->
        LemonCore.CLI.error("Delete failed: #{inspect(reason)}")
        LemonCore.CLI.fail!("Delete failed")
    end
  end

  defp manage_drafts(_) do
    LemonCore.CLI.info("""
    Manage synthesized skill drafts.

    Usage:
      lemon skill draft list              # List all drafts
      lemon skill draft generate          # Synthesize new drafts from run history
      lemon skill draft review <key>      # Review a draft's content
      lemon skill draft publish <key>     # Promote a draft to an installed skill
      lemon skill draft delete <key>      # Delete a draft

    Options:
      --local                    Work with project-local drafts (default: global)
      --cwd=<path>               Project directory for --local
      --agent=<id>               Agent ID for generate (default: LEMON_AGENT_ID env)
      --max-docs=<n>             Max memory docs to consider for generate (default: 50)
      --force                    Overwrite existing draft / installed skill
    """)
  end

  # ============================================================================
  # Curator Commands
  # ============================================================================

  defp manage_curator(["status" | opts]) do
    curator_opts = curator_opts(opts)
    state = Curator.load_state(curator_opts)
    rows = Curator.candidate_rows(curator_opts)
    status = if state["paused"], do: "paused", else: "enabled"

    LemonCore.CLI.info("curator: #{status}")
    LemonCore.CLI.info("  runs:          #{state["run_count"]}")
    LemonCore.CLI.info("  last run:      #{state["last_run_at"] || "never"}")
    LemonCore.CLI.info("  last summary:  #{state["last_run_summary"] || "(none)"}")
    LemonCore.CLI.info("  candidates:    #{length(rows)}")

    if rows != [] do
      LemonCore.CLI.info("\nAgent-authored skills:")

      Enum.each(rows, fn row ->
        LemonCore.CLI.info(
          "  #{row.name} state=#{row.lifecycle_state} loads=#{row.load_count} writes=#{row.write_count} idle_days=#{row.idle_days || "unknown"}"
        )
      end)
    end
  end

  defp manage_curator(["run" | opts]) do
    curator_opts = curator_opts(opts)

    case Curator.run(curator_opts) do
      {:ok, result} ->
        LemonCore.CLI.info("curator: #{result.summary}")
        LemonCore.CLI.info("  candidates: #{length(result.candidates)}")

        if "--prompt" in opts do
          LemonCore.CLI.info("\n--- Curator review prompt ---\n")
          LemonCore.CLI.info(result.review_prompt)
        else
          LemonCore.CLI.info("\nPass --prompt to print the agent review prompt.")
        end

      {:error, reason} ->
        LemonCore.CLI.error("curator failed: #{inspect(reason)}")
        LemonCore.CLI.fail!("Curator failed")
    end
  end

  defp manage_curator(["pause" | opts]) do
    :ok = Curator.set_paused(true, curator_opts(opts))
    LemonCore.CLI.info("curator: paused")
  end

  defp manage_curator(["resume" | opts]) do
    :ok = Curator.set_paused(false, curator_opts(opts))
    LemonCore.CLI.info("curator: resumed")
  end

  defp manage_curator(_) do
    LemonCore.CLI.info("""
    Manage skill curation.

    Usage:
      lemon skill curator status          # Show curator state and candidates
      lemon skill curator run             # Apply lifecycle transitions
      lemon skill curator run --prompt    # Also print the agent review prompt
      lemon skill curator pause           # Pause scheduled curator checks
      lemon skill curator resume          # Resume scheduled curator checks

    Options:
      --local                    Work with project-local skill usage (default: global)
      --cwd=<path>               Project directory for --local
      --stale-after-days=<n>     Mark agent-authored skills stale after n idle days
      --archive-after-days=<n>   Archive agent-authored skills after n idle days
    """)
  end

  defp get_opt(opts, flag, default) do
    case Enum.find(opts, &String.starts_with?(&1, "#{flag}=")) do
      nil -> default
      opt -> String.replace_prefix(opt, "#{flag}=", "")
    end
  end

  defp print_usage do
    LemonCore.CLI.info(@moduledoc)
  end

  # ============================================================================
  # Formatting Helpers
  # ============================================================================

  defp format_activation(:active), do: "active"
  defp format_activation(:not_ready), do: "not_ready"
  defp format_activation(:hidden), do: "hidden"
  defp format_activation(:platform_incompatible), do: "platform_incompatible"
  defp format_activation(:blocked), do: "blocked"
  defp format_activation(:unaudited), do: "unaudited"
  defp format_activation(other), do: inspect(other)

  defp format_activation_short(:active), do: "✓ active"
  defp format_activation_short(:not_ready), do: "✗ not_ready"
  defp format_activation_short(:hidden), do: "~ hidden"
  defp format_activation_short(:platform_incompatible), do: "~ incompatible"
  defp format_activation_short(:blocked), do: "✗ blocked"
  defp format_activation_short(:unaudited), do: "✗ unaudited"
  defp format_activation_short(other), do: inspect(other)

  defp format_source(:global), do: "Global"
  defp format_source(:project), do: "Project"
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

  defp stored_install_hash(%Entry{bundle_hash: hash}) when is_binary(hash), do: hash
  defp stored_install_hash(%Entry{content_hash: hash}), do: hash

  defp current_install_hash(%Entry{bundle_hash: hash} = entry) when is_binary(hash) do
    Entry.compute_bundle_hash(entry)
  end

  defp current_install_hash(%Entry{} = entry), do: Entry.compute_content_hash(entry)

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

  defp curator_opts(opts) do
    global = "--local" not in opts

    [
      scope: if(global, do: :global, else: :project),
      cwd: unless(global, do: get_cwd(opts)),
      stale_after_days: get_int_opt(opts, "--stale-after-days", 30),
      archive_after_days: get_int_opt(opts, "--archive-after-days", 90)
    ]
  end
end
