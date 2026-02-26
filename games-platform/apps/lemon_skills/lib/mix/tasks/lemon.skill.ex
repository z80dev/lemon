defmodule Mix.Tasks.Lemon.Skill do
  @moduledoc """
  Manage Lemon skills from the command line.

  This task provides commands for discovering, installing, updating, and
  removing skills. It integrates with the online skill discovery system
  to find skills from GitHub and other sources.

  ## Commands

      mix lemon.skill list              # List installed skills
      mix lemon.skill search <query>    # Search for skills (local + online)
      mix lemon.skill discover <query>  # Discover skills from GitHub
      mix lemon.skill install <source>  # Install a skill from URL or path
      mix lemon.skill update <key>      # Update an installed skill
      mix lemon.skill remove <key>      # Remove an installed skill
      mix lemon.skill info <key>        # Show skill details

  ## Examples

      # List all installed skills
      mix lemon.skill list

      # Search for skills related to "web"
      mix lemon.skill search web

      # Discover skills from GitHub
      mix lemon.skill discover api

      # Install a skill from GitHub
      mix lemon.skill install https://github.com/user/lemon-skill-name

      # Install a skill locally (project-only)
      mix lemon.skill install /path/to/skill --local

      # Update a skill
      mix lemon.skill update my-skill

      # Remove a skill
      mix lemon.skill remove my-skill

      # Show skill details
      mix lemon.skill info my-skill

  ## Global vs Local Installation

  By default, skills are installed globally in `~/.lemon/agent/skill/`.
  Use `--local` to install in the current project's `.lemon/skill/` directory.
  """

  use Mix.Task

  alias LemonSkills.{Registry, Installer, Entry}

  @impl true
  def run(args) do
    # Ensure the application is started
    Mix.Task.run("app.start")

    case args do
      ["list" | opts] ->
        list_skills(opts)

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

      ["info", key | opts] ->
        show_skill_info(key, opts)

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
        Mix.shell().info([:green, "✓", :reset, " Successfully installed '#{entry.key}'"])
        Mix.shell().info("  Path: #{entry.path}")
        Mix.shell().info("  Source: #{entry.source}")

        if entry.manifest do
          Mix.shell().info("  Name: #{entry.manifest.name}")
          Mix.shell().info("  Description: #{entry.manifest.description}")
        end

      {:error, reason} ->
        Mix.shell().error([:red, "✗", :reset, " Installation failed: #{reason}"])
        Mix.raise("Skill installation failed")
    end

    :ok
  end

  # ============================================================================
  # Update Command
  # ============================================================================

  defp update_skill(key, opts) do
    cwd = get_cwd(opts)

    Mix.shell().info("Updating skill '#{key}'...")

    case Installer.update(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        Mix.shell().info([:green, "✓", :reset, " Successfully updated '#{entry.key}'"])
        Mix.shell().info("  Path: #{entry.path}")

      {:error, reason} ->
        Mix.shell().error([:red, "✗", :reset, " Update failed: #{reason}"])
        Mix.raise("Skill update failed")
    end

    :ok
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
        Mix.shell().error([:red, "✗", :reset, " Removal failed: #{reason}"])
        Mix.raise("Skill removal failed")
    end

    :ok
  end

  # ============================================================================
  # Info Command
  # ============================================================================

  defp show_skill_info(key, opts) do
    cwd = get_cwd(opts)

    case Registry.get(key, cwd: cwd) do
      {:ok, %Entry{} = entry} ->
        print_skill_details(entry)

      :error ->
        Mix.shell().error("Skill '#{key}' not found.")
        Mix.shell().info("\nUse 'mix lemon.skill list' to see installed skills.")
        Mix.shell().info("Use 'mix lemon.skill search #{key}' to find similar skills.")
        Mix.raise("Skill not found")
    end

    :ok
  end

  # ============================================================================
  # Output Helpers
  # ============================================================================

  defp print_skills_table(skills, _cwd) do
    # Header
    IO.puts("\n#{String.pad_trailing("KEY", 20)} #{String.pad_trailing("STATUS", 10)} #{String.pad_trailing("SOURCE", 10)} DESCRIPTION")
    IO.puts(String.duplicate("-", 80))

    # Rows
    Enum.each(skills, fn %Entry{} = entry ->
      status = if entry.enabled, do: "enabled", else: "disabled"
      source = Atom.to_string(entry.source)
      desc = get_description(entry)
      desc = if String.length(desc) > 35, do: String.slice(desc, 0, 32) <> "...", else: desc

      IO.puts("#{String.pad_trailing(entry.key, 20)} #{String.pad_trailing(status, 10)} #{String.pad_trailing(source, 10)} #{desc}")
    end)

    IO.puts("\n#{length(skills)} skill(s) found.")
  end

  defp print_discovery_results(results) do
    # Header
    IO.puts("\n#{String.pad_trailing("NAME", 25)} #{String.pad_trailing("SOURCE", 10)} VALIDATED DESCRIPTION")
    IO.puts(String.duplicate("-", 80))

    # Rows
    Enum.each(results, fn %{entry: entry, source: source, validated: validated, url: url} ->
      name = entry.key
      source_str = Atom.to_string(source)
      validated_str = if validated, do: "✓", else: "✗"
      desc = entry.manifest && entry.manifest.description || ""
      desc = if String.length(desc) > 30, do: String.slice(desc, 0, 27) <> "...", else: desc

      IO.puts("#{String.pad_trailing(name, 25)} #{String.pad_trailing(source_str, 10)} #{validated_str}         #{desc}")
      IO.puts("  URL: #{url}")
    end)

    IO.puts("\n#{length(results)} skill(s) found.")
    IO.puts("\nInstall with: mix lemon.skill install <URL>")
  end

  defp print_skill_details(%Entry{} = entry) do
    IO.puts("\n=== Skill: #{entry.key} ===")
    IO.puts("")
    IO.puts("Key:        #{entry.key}")
    IO.puts("Name:       #{entry.name}")
    IO.puts("Path:       #{entry.path}")
    IO.puts("Source:     #{entry.source}")
    IO.puts("Enabled:    #{entry.enabled}")
    IO.puts("Status:     #{entry.status}")

    if entry.manifest do
      IO.puts("")
      IO.puts("--- Manifest ---")
      IO.puts("Name:        #{entry.manifest.name}")
      IO.puts("Description: #{entry.manifest.description}")

      if entry.manifest.version do
        IO.puts("Version:     #{entry.manifest.version}")
      end

      if entry.manifest.keywords != [] do
        IO.puts("Keywords:    #{Enum.join(entry.manifest.keywords, ", ")}")
      end

      if entry.manifest.inputs != [] do
        IO.puts("Inputs:      #{Enum.join(entry.manifest.inputs, ", ")}")
      end

      if entry.manifest.outputs != [] do
        IO.puts("Outputs:     #{Enum.join(entry.manifest.outputs, ", ")}")
      end
    end

    IO.puts("")
  end

  defp print_usage do
    Mix.shell().info(@moduledoc)
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_description(%Entry{description: description}) when is_binary(description) and description != "" do
    description
  end

  defp get_description(%Entry{manifest: nil}), do: ""

  defp get_description(%Entry{manifest: manifest}) when is_map(manifest) do
    # Handle both string and atom keys
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
      nil -> default
      opt ->
        opt
        |> String.replace_prefix("#{flag}=", "")
        |> String.to_integer()
    end
  end
end
