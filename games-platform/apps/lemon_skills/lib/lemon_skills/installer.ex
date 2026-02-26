defmodule LemonSkills.Installer do
  @moduledoc """
  Skill installation and update management.

  Handles installing skills from various sources:
  - Git repositories
  - Local paths
  - Skill registries (future)

  ## Installation Process

  1. Parse source URL/path
  2. Validate skill structure (SKILL.md exists)
  3. Check for existing installation
  4. Request approval if needed (via ApprovalsBridge)
  5. Copy/clone to target directory
  6. Register with the skill registry

  ## Approval Gating

  Per parity requirement, skill install/update/uninstall operations
  require user approval. Approval can be:

  - Pre-approved via `:approve` option
  - Requested at runtime via ApprovalsBridge
  - Configured globally via skill policy settings
  """

  alias LemonSkills.{Registry, Entry, Manifest, Config}

  require Logger

  @type install_result :: {:ok, Entry.t()} | {:error, term()}

  @doc """
  Install a skill from a source.

  ## Parameters

  - `source` - The source URL or path

  ## Options

  - `:cwd` - Project working directory for local installation
  - `:global` - Install globally (default: true)
  - `:approve` - Pre-approve installation (default: false)
  - `:force` - Overwrite existing installation (default: false)

  ## Examples

      {:ok, entry} = LemonSkills.Installer.install("https://github.com/user/skill")
      {:ok, entry} = LemonSkills.Installer.install("/local/path", global: false)
  """
  @spec install(String.t(), keyword()) :: install_result()
  def install(source, opts \\ []) do
    global = Keyword.get(opts, :global, true)
    force = Keyword.get(opts, :force, false)
    cwd = Keyword.get(opts, :cwd)
    approve = Keyword.get(opts, :approve, false)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    run_id = Keyword.get(opts, :run_id)

    with {:ok, source_type, resolved} <- resolve_source(source),
         {:ok, skill_name} <- extract_skill_name(resolved, source_type),
         :ok <- check_existing(skill_name, global, cwd, force),
         :ok <- request_approval_if_needed(:install, skill_name, source, approve, %{
           session_key: session_key,
           agent_id: agent_id,
           run_id: run_id
         }),
         {:ok, target_dir} <- determine_target_dir(skill_name, global, cwd),
         :ok <- ensure_target_exists(target_dir),
         {:ok, _} <- perform_install(source_type, resolved, target_dir),
         {:ok, entry} <- load_installed_skill(target_dir, global) do
      Registry.register(entry)
      {:ok, entry}
    end
  end

  @doc """
  Update an installed skill.

  ## Parameters

  - `key` - The skill key to update

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec update(String.t(), keyword()) :: install_result()
  def update(key, opts \\ []) do
    approve = Keyword.get(opts, :approve, false)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    run_id = Keyword.get(opts, :run_id)

    case Registry.get(key, opts) do
      {:ok, entry} ->
        with :ok <- request_approval_if_needed(:update, key, entry.path, approve, %{
               session_key: session_key,
               agent_id: agent_id,
               run_id: run_id
             }) do
          update_entry(entry)
        end

      :error ->
        {:error, "Skill not found: #{key}"}
    end
  end

  @doc """
  Uninstall a skill.

  ## Parameters

  - `key` - The skill key to uninstall

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec uninstall(String.t(), keyword()) :: :ok | {:error, term()}
  def uninstall(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    approve = Keyword.get(opts, :approve, false)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    run_id = Keyword.get(opts, :run_id)

    case Registry.get(key, opts) do
      {:ok, entry} ->
        with :ok <- request_approval_if_needed(:uninstall, key, entry.path, approve, %{
               session_key: session_key,
               agent_id: agent_id,
               run_id: run_id
             }) do
          # Remove from filesystem
          case File.rm_rf(entry.path) do
            {:ok, _} ->
              # Unregister
              Registry.unregister(key, entry.source, cwd)
              :ok

            {:error, reason, _path} ->
              {:error, "Failed to remove skill directory: #{reason}"}
          end
        end

      :error ->
        {:error, "Skill not found: #{key}"}
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_source(source) do
    cond do
      # Git URL
      String.starts_with?(source, "https://") or String.starts_with?(source, "git@") ->
        {:ok, :git, source}

      # Local path
      File.dir?(source) ->
        {:ok, :local, Path.expand(source)}

      # Could be a registry reference (future)
      String.match?(source, ~r/^[a-z0-9_-]+\/[a-z0-9_-]+$/i) ->
        {:error, "Registry references not yet supported: #{source}"}

      true ->
        {:error, "Unknown source type: #{source}"}
    end
  end

  defp extract_skill_name(resolved, :git) do
    # Extract repo name from URL
    name =
      resolved
      |> String.split("/")
      |> List.last()
      |> String.trim_trailing(".git")

    {:ok, name}
  end

  defp extract_skill_name(resolved, :local) do
    {:ok, Path.basename(resolved)}
  end

  defp check_existing(name, global, cwd, force) do
    target =
      if global do
        Path.join(Config.global_skills_dir(), name)
      else
        Path.join(Config.project_skills_dir(cwd), name)
      end

    if File.dir?(target) and not force do
      {:error, "Skill already installed at #{target}. Use force: true to overwrite."}
    else
      :ok
    end
  end

  defp determine_target_dir(name, true, _cwd) do
    {:ok, Path.join(Config.global_skills_dir(), name)}
  end

  defp determine_target_dir(name, false, cwd) when is_binary(cwd) do
    {:ok, Path.join(Config.project_skills_dir(cwd), name)}
  end

  defp determine_target_dir(_name, false, nil) do
    {:error, "Project directory (cwd) required for local installation"}
  end

  defp ensure_target_exists(target_dir) do
    parent = Path.dirname(target_dir)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create directory: #{reason}"}
    end
  end

  defp perform_install(:git, url, target_dir) do
    # Remove existing if present
    File.rm_rf(target_dir)

    case System.cmd("git", ["clone", "--depth", "1", url, target_dir], stderr_to_stdout: true) do
      {_output, 0} ->
        # Remove .git directory to save space
        File.rm_rf(Path.join(target_dir, ".git"))
        {:ok, target_dir}

      {output, _code} ->
        {:error, "Git clone failed: #{output}"}
    end
  end

  defp perform_install(:local, source_dir, target_dir) do
    # Validate source has SKILL.md
    skill_file = Path.join(source_dir, "SKILL.md")

    if File.exists?(skill_file) do
      # Copy entire directory
      File.rm_rf(target_dir)

      case File.cp_r(source_dir, target_dir) do
        {:ok, _} -> {:ok, target_dir}
        {:error, reason, _path} -> {:error, "Copy failed: #{reason}"}
      end
    else
      {:error, "Source directory missing SKILL.md: #{source_dir}"}
    end
  end

  defp load_installed_skill(path, global) do
    source = if global, do: :global, else: :project
    entry = Entry.new(path, source: source)
    skill_file = Entry.skill_file(entry)

    case File.read(skill_file) do
      {:ok, content} ->
        case Manifest.parse(content) do
          {:ok, manifest, _body} ->
            {:ok, Entry.with_manifest(entry, manifest)}

          :error ->
            {:ok, entry}
        end

      {:error, reason} ->
        {:error, "Failed to read SKILL.md: #{reason}"}
    end
  end

  defp update_entry(%Entry{source: source_url}) when is_binary(source_url) do
    # Re-install from original source
    install(source_url, force: true)
  end

  defp update_entry(%Entry{path: path, source: :git}) do
    # Try git pull if .git exists
    git_dir = Path.join(path, ".git")

    if File.dir?(git_dir) do
      case System.cmd("git", ["-C", path, "pull"], stderr_to_stdout: true) do
        {_output, 0} ->
          # Reload entry
          load_installed_skill(path, true)

        {output, _code} ->
          {:error, "Git pull failed: #{output}"}
      end
    else
      {:error, "Cannot update: skill was not installed from git or .git directory was removed"}
    end
  end

  defp update_entry(%Entry{}) do
    {:error, "Cannot update: skill source is not a remote URL"}
  end

  # ============================================================================
  # Approval Gating
  # ============================================================================

  @doc false
  # Request approval for skill operations if not pre-approved
  defp request_approval_if_needed(_operation, _skill_name, _source, true, _ctx) do
    # Pre-approved via opts
    :ok
  end

  defp request_approval_if_needed(operation, skill_name, source, false, ctx) do
    # Check if approvals are enabled
    if approvals_enabled?() do
      request_skill_approval(operation, skill_name, source, ctx)
    else
      :ok
    end
  end

  defp approvals_enabled? do
    Application.get_env(:lemon_skills, :require_approval, true)
  end

  defp request_skill_approval(operation, skill_name, source, ctx) do
    tool = "skills.#{operation}"

    action = %{
      operation: operation,
      skill_name: skill_name,
      source: source
    }

    rationale = build_rationale(operation, skill_name, source)

    timeout_ms = Application.get_env(:lemon_skills, :approval_timeout_ms, 300_000)

    params = %{
      run_id: ctx[:run_id],
      session_key: ctx[:session_key],
      agent_id: ctx[:agent_id],
      tool: tool,
      action: action,
      rationale: rationale,
      expires_in_ms: timeout_ms
    }

    Logger.info(
      "[SkillInstaller] Requesting approval for #{operation} of skill '#{skill_name}'"
    )

    case LemonCore.ExecApprovals.request(params) do
      {:ok, :approved, scope} ->
        Logger.info(
          "[SkillInstaller] #{operation} approved at scope #{scope} for skill '#{skill_name}'"
        )

        :ok

      {:ok, :denied} ->
        Logger.warning("[SkillInstaller] #{operation} denied for skill '#{skill_name}'")
        {:error, "Skill #{operation} denied by user"}

      {:error, :timeout} ->
        Logger.warning("[SkillInstaller] #{operation} approval timed out for skill '#{skill_name}'")
        {:error, "Skill #{operation} approval timed out"}
    end
  rescue
    _ ->
      # If approvals infrastructure isn't available, default to allowing so the
      # installer can still be used in minimal runtimes.
      :ok
  end

  defp build_rationale(:install, skill_name, source) do
    "Install skill '#{skill_name}' from #{source}"
  end

  defp build_rationale(:update, skill_name, _source) do
    "Update skill '#{skill_name}' to latest version"
  end

  defp build_rationale(:uninstall, skill_name, _source) do
    "Uninstall skill '#{skill_name}'"
  end
end
