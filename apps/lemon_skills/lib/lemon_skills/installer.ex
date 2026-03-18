defmodule LemonSkills.Installer do
  @moduledoc """
  Skill installation and update management.

  Handles installing skills from various sources using the source abstraction
  layer (`LemonSkills.Source` + `LemonSkills.SourceRouter`).

  ## Installation flow

      resolve → plan → check_existing → approve → fetch_to_staging
        → load_manifest → audit_entry → activate → write_lockfile → register

  ## Update flow

      lookup → get upstream_hash → compare with current install hash
        → if drifted: fetch_to_staging → load_manifest → activate → write_lockfile → register
        → if current: no-op

  ## Approval gating

  Per parity requirement, skill install/update/uninstall operations require
  user approval. Override via `:approve` option or configure globally.
  """

  alias LemonSkills.{
    Audit.State,
    Config,
    Entry,
    InstallPlan,
    Lockfile,
    Manifest,
    Registry,
    SourceRouter,
    TrustPolicy
  }

  alias LemonSkills.Audit.BundleAudit

  require Logger

  @type install_result :: {:ok, Entry.t()} | {:error, term()}

  @doc """
  Install a skill from a source identifier.

  Accepts any identifier understood by `LemonSkills.SourceRouter.resolve/1`:
  local paths, git URLs, `gh:owner/repo`, registry refs, etc.

  ## Options

  - `:cwd` — project directory; required when `global: false`
  - `:global` — install globally (default: `true`)
  - `:approve` — pre-approve installation (default: `false`)
  - `:force` — overwrite existing installation (default: `false`)
  - `:branch` — git branch for `:git` sources (default: `"main"`)

  ## Examples

      {:ok, entry} = Installer.install("https://github.com/acme/k8s-skill")
      {:ok, entry} = Installer.install("official/devops/k8s-rollout")
      {:ok, entry} = Installer.install("/local/path", global: false, cwd: "/myproject")
  """
  @spec install(String.t(), keyword()) :: install_result()
  def install(source, opts \\ []) do
    global = Keyword.get(opts, :global, true)
    cwd = Keyword.get(opts, :cwd)

    with {:ok, plan} <- build_plan(source, global, cwd, opts),
         :ok <- check_existing(plan),
         :ok <-
           request_approval_if_needed(:install, plan.skill_name, source, plan.trust_level, opts) do
      previous_entry = existing_entry(plan)

      with_staged_fetch(plan.source_module, plan.source_id, plan.dest_dir, opts, fn staged_dir ->
        with {:ok, entry} <- load_entry_from_dir(staged_dir, plan),
             {:ok, entry} <- audit_entry(entry, plan.scope, opts),
             :ok <- check_audit_verdict(entry),
             :ok <- request_audit_warning_approval_if_needed(:install, entry, source, opts),
             {:ok, activation} <- activate_staged_install(staged_dir, plan.dest_dir, plan.force),
             {:ok, entry} <-
               persist_activated_install(plan.scope, entry, activation, previous_entry) do
          {:ok, entry}
        end
      end)
    end
  end

  defp check_audit_verdict(%Entry{audit_status: :block, audit_findings: findings}) do
    reason =
      findings
      |> Enum.take(3)
      |> Enum.join("; ")

    {:error, "Skill blocked by security audit: #{reason}"}
  end

  defp check_audit_verdict(_entry), do: :ok

  @doc """
  Update an installed skill.

  Checks the upstream hash (when available) and skips the reinstall if the
  installed content already matches. Falls back to a full reinstall when
  the source module does not support remote hash queries.

  ## Options

  - `:cwd` — project directory (optional)
  - `:approve` — pre-approve (default: `false`)
  - `:force` — force reinstall even when up-to-date (default: `false`)
  """
  @spec update(String.t(), keyword()) :: install_result()
  def update(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    force = Keyword.get(opts, :force, false)

    case Registry.get(key, opts) do
      {:ok, entry} ->
        with :ok <- request_approval_if_needed(:update, key, entry.path, entry.trust_level, opts) do
          update_entry(entry, force, cwd, opts)
        end

      :error ->
        {:error, "Skill not found: #{key}"}
    end
  end

  @doc """
  Uninstall a skill.

  Removes the skill directory, lockfile record, and registry entry.

  ## Options

  - `:cwd` — project directory (optional)
  - `:approve` — pre-approve (default: `false`)
  """
  @spec uninstall(String.t(), keyword()) :: :ok | {:error, term()}
  def uninstall(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)

    case Registry.get(key, opts) do
      {:ok, entry} ->
        with :ok <-
               request_approval_if_needed(:uninstall, key, entry.path, entry.trust_level, opts) do
          scope = entry_scope(entry, cwd)

          case File.rm_rf(entry.path) do
            {:ok, _} ->
              Lockfile.delete(scope, key)
              State.delete(scope, :skill, key)
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
  # Plan building
  # ============================================================================

  defp build_plan(source, global, cwd, opts) do
    with {:ok, mod, id} <- SourceRouter.resolve(source),
         {:ok, skill_name} <- derive_skill_name(id, source, mod),
         {:ok, dest_dir} <- determine_target_dir(skill_name, global, cwd),
         {:ok, parent_dir} <- ensure_parent_dir(dest_dir) do
      _ = parent_dir

      source_kind = SourceRouter.source_kind(mod)

      trust_level =
        if function_exported?(mod, :trust_for_ref, 1) do
          mod.trust_for_ref(id)
        else
          mod.trust_level()
        end

      force = Keyword.get(opts, :force, false)
      scope = if global, do: :global, else: {:project, cwd}

      plan = %InstallPlan{
        source_module: mod,
        source_id: id,
        source_kind: source_kind,
        trust_level: trust_level,
        skill_name: skill_name,
        dest_dir: dest_dir,
        scope: scope,
        force: force
      }

      {:ok, plan}
    end
  end

  defp derive_skill_name(nil, _source, _mod) do
    {:error, "Cannot determine skill name for builtin source; use BuiltinSeeder instead"}
  end

  defp derive_skill_name(id, _source, _mod) when is_binary(id) do
    name =
      id
      |> String.split("/")
      |> List.last()
      |> String.trim_trailing(".git")

    if name == "" do
      {:error, "Cannot derive skill name from identifier: #{inspect(id)}"}
    else
      {:ok, name}
    end
  end

  defp determine_target_dir(name, true, _cwd) do
    {:ok, Path.join(Config.global_skills_dir(), name)}
  end

  defp determine_target_dir(name, false, cwd) when is_binary(cwd) do
    {:ok, Path.join(Config.project_skills_dir(cwd), name)}
  end

  defp determine_target_dir(_name, false, nil) do
    {:error, "Project directory (cwd) required for project-local installation"}
  end

  defp ensure_parent_dir(dest_dir) do
    parent = Path.dirname(dest_dir)

    case File.mkdir_p(parent) do
      :ok -> {:ok, parent}
      {:error, reason} -> {:error, "Failed to create directory: #{reason}"}
    end
  end

  # ============================================================================
  # Pre-flight checks
  # ============================================================================

  defp check_existing(%InstallPlan{dest_dir: dest_dir, force: force, skill_name: name}) do
    if File.dir?(dest_dir) and not force do
      {:error, "Skill '#{name}' already installed at #{dest_dir}. Pass force: true to overwrite."}
    else
      :ok
    end
  end

  # ============================================================================
  # Post-fetch helpers
  # ============================================================================

  defp with_staged_fetch(source_module, source_id, final_dest, opts, fun)
       when is_function(fun, 1) do
    staged_dir = staging_dir(final_dest)

    try do
      with {:ok, fetched_dir} <- source_module.fetch(source_id, staged_dir, opts) do
        fun.(fetched_dir)
      end
    after
      cleanup_staging_dir(staged_dir)
    end
  end

  defp load_entry_from_dir(dest_dir, %InstallPlan{} = plan) do
    source = scope_to_source_atom(plan.scope)

    entry =
      Entry.new(dest_dir,
        source: source,
        source_kind: plan.source_kind,
        source_id: plan.source_id,
        trust_level: plan.trust_level,
        installed_at: DateTime.utc_now()
      )
      |> Map.put(:key, plan.skill_name)

    skill_file = Entry.skill_file(entry)

    case File.read(skill_file) do
      {:ok, content} ->
        case Manifest.parse_and_validate(content) do
          {:ok, manifest, _body} ->
            entry =
              entry
              |> Entry.with_manifest(manifest)
              |> Map.put(:content_hash, Entry.compute_content_hash(entry))
              |> Map.put(:bundle_hash, Entry.compute_bundle_hash(entry))

            {:ok, entry}

          {:error, reason} ->
            {:error, "Invalid SKILL.md manifest: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to read SKILL.md after install: #{reason}"}
    end
  end

  defp audit_entry(%Entry{trust_level: trust_level} = entry, scope, opts) do
    if TrustPolicy.requires_audit?(trust_level) do
      with {:ok, result} <-
             BundleAudit.audit(entry.path, scope, entry.key, Keyword.put(opts, :kind, :skill)) do
        {:ok,
         %{
           entry
           | bundle_hash: result["bundle_hash"] || entry.bundle_hash,
             audit_status: BundleAudit.audit_status(result),
             audit_findings: BundleAudit.audit_findings(result)
         }}
      end
    else
      {:ok, %{entry | audit_status: :pass, audit_findings: []}}
    end
  end

  defp write_lockfile(scope, entry) do
    record = Entry.to_lockfile_record(entry)

    case Lockfile.put(scope, record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Installer] could not write lockfile for '#{entry.key}': #{inspect(reason)}"
        )

        {:error, {:lockfile_write_failed, reason}}
    end
  end

  defp activate_staged_install(staged_dir, final_dest, force) do
    cond do
      staged_dir == final_dest ->
        {:ok, %{final_dest: final_dest, backup_dir: nil}}

      File.exists?(final_dest) and not force ->
        {:error, "Skill destination already exists at #{final_dest}"}

      true ->
        backup_dir =
          if File.exists?(final_dest) do
            backup_dir(final_dest)
          else
            nil
          end

        with :ok <- move_existing_dest_to_backup(final_dest, backup_dir) do
          case move_staged_into_place(staged_dir, final_dest) do
            :ok ->
              {:ok, %{final_dest: final_dest, backup_dir: backup_dir}}

            {:error, reason} = error ->
              rollback_activation(%{final_dest: final_dest, backup_dir: backup_dir})

              Logger.warning(
                "[Installer] activation failed for '#{final_dest}': #{inspect(reason)}"
              )

              error
          end
        end
    end
  end

  defp persist_activated_install(scope, entry, activation, previous_entry) do
    live_entry = %{entry | path: activation.final_dest}

    case persist_entry_metadata(scope, live_entry, previous_entry) do
      :ok ->
        cleanup_backup_dir(activation.backup_dir)
        {:ok, live_entry}

      {:error, reason} ->
        rollback_activation(activation)
        {:error, reason}
    end
  end

  # ============================================================================
  # Update logic
  # ============================================================================

  defp update_entry(entry, force, cwd, opts) do
    case resolve_update_source(entry) do
      {:ok, mod, id} ->
        if force do
          perform_full_reinstall(entry, mod, id, cwd, opts)
        else
          check_drift_and_update(entry, mod, id, cwd, opts)
        end

      :no_source ->
        # No provenance data — fall back to legacy path (re-install from source field).
        legacy_update(entry)
    end
  end

  defp resolve_update_source(%Entry{source_id: id, source_kind: kind})
       when is_binary(id) and not is_nil(kind) do
    # Re-resolve from source_id so we get the right module.
    case SourceRouter.resolve(id) do
      {:ok, mod, canonical} -> {:ok, mod, canonical}
      {:error, _} -> :no_source
    end
  end

  defp resolve_update_source(%Entry{source: source}) when is_binary(source) do
    # Legacy: source field holds a URL.
    case SourceRouter.resolve(source) do
      {:ok, mod, canonical} -> {:ok, mod, canonical}
      {:error, _} -> :no_source
    end
  end

  defp resolve_update_source(_), do: :no_source

  defp check_drift_and_update(entry, mod, id, cwd, opts) do
    case mod.upstream_hash(id, opts) do
      {:ok, upstream} ->
        current_hash = current_install_hash(entry)

        if is_binary(current_hash) and upstream == current_hash do
          persist_current_upstream_hash(entry, cwd, upstream)
        else
          perform_full_reinstall(entry, mod, id, cwd, Keyword.put(opts, :upstream_hash, upstream))
        end

      {:error, :unsupported} ->
        # Source does not support remote hash — reinstall to be safe.
        perform_full_reinstall(entry, mod, id, cwd, opts)

      {:error, reason} ->
        Logger.warning("[Installer] upstream_hash failed for '#{entry.key}': #{inspect(reason)}")
        perform_full_reinstall(entry, mod, id, cwd, opts)
    end
  end

  defp perform_full_reinstall(entry, mod, id, cwd, opts) do
    scope = entry_scope(entry, cwd)
    global = scope == :global
    new_upstream_hash = Keyword.get(opts, :upstream_hash)

    build_plan_opts =
      opts
      |> Keyword.put(:force, true)
      |> Keyword.put(:global, global)
      |> (fn o -> if cwd, do: Keyword.put(o, :cwd, cwd), else: o end).()

    with_staged_fetch(mod, id, entry.path, build_plan_opts, fn staged_dir ->
      with {:ok, updated_entry} <-
             load_entry_from_dir(staged_dir, %InstallPlan{
               source_module: mod,
               source_id: id,
               source_kind: entry.source_kind || SourceRouter.source_kind(mod),
               trust_level: entry.trust_level || mod.trust_level(),
               skill_name: entry.key,
               dest_dir: entry.path,
               scope: scope
             }),
           updated_entry <- %{
             updated_entry
             | installed_at: entry.installed_at || updated_entry.installed_at,
               updated_at: DateTime.utc_now()
           },
           updated_entry <- maybe_set_upstream_hash(updated_entry, new_upstream_hash),
           {:ok, updated_entry} <- audit_entry(updated_entry, scope, opts),
           :ok <- check_audit_verdict(updated_entry),
           :ok <- request_audit_warning_approval_if_needed(:update, updated_entry, id, opts),
           {:ok, activation} <- activate_staged_install(staged_dir, entry.path, true),
           {:ok, updated_entry} <-
             persist_activated_install(scope, updated_entry, activation, entry) do
        {:ok, updated_entry}
      end
    end)
  end

  defp maybe_set_upstream_hash(entry, nil), do: entry
  defp maybe_set_upstream_hash(entry, hash), do: %{entry | upstream_hash: hash}

  defp persist_current_upstream_hash(entry, cwd, upstream) do
    if entry.upstream_hash == upstream do
      {:ok, entry}
    else
      scope = entry_scope(entry, cwd)
      refreshed_entry = maybe_set_upstream_hash(entry, upstream)

      case persist_entry_metadata(scope, refreshed_entry, entry) do
        :ok -> {:ok, refreshed_entry}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp staging_dir(final_dest) do
    parent = Path.dirname(final_dest)
    name = Path.basename(final_dest)
    Path.join(parent, ".#{name}.staging-#{System.unique_integer([:positive])}")
  end

  defp cleanup_staging_dir(staged_dir) do
    if File.exists?(staged_dir) do
      File.rm_rf(staged_dir)
    end
  end

  defp persist_entry_metadata(scope, entry, previous_entry) do
    previous_record =
      if previous_entry do
        Entry.to_lockfile_record(previous_entry)
      else
        nil
      end

    with :ok <- write_lockfile(scope, entry),
         :ok <- safe_register(entry) do
      :ok
    else
      {:error, reason} = error ->
        restore_metadata(scope, entry, previous_entry, previous_record)

        Logger.warning(
          "[Installer] metadata persistence failed for '#{entry.key}': #{inspect(reason)}"
        )

        error
    end
  end

  defp safe_register(entry) do
    try do
      :ok = Registry.register(entry)
      :ok
    catch
      :exit, reason ->
        {:error, {:registry_register_failed, reason}}
    end
  end

  defp restore_metadata(scope, entry, previous_entry, previous_record) do
    restore_lockfile_record(scope, entry.key, previous_record)
    restore_registry_entry(entry, previous_entry, scope)
  end

  defp restore_lockfile_record(scope, key, nil) do
    case Lockfile.delete(scope, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Installer] rollback lockfile delete failed: #{inspect(reason)}")
    end
  end

  defp restore_lockfile_record(scope, _key, previous_record) do
    case Lockfile.put(scope, previous_record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Installer] rollback lockfile restore failed: #{inspect(reason)}")
    end
  end

  defp restore_registry_entry(entry, nil, scope) do
    cwd = scope_cwd(scope)

    try do
      Registry.unregister(entry.key, entry.source, cwd)
    catch
      :exit, reason ->
        Logger.warning("[Installer] rollback registry unregister failed: #{inspect(reason)}")
    end
  end

  defp restore_registry_entry(_entry, previous_entry, _scope) do
    case safe_register(previous_entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Installer] rollback registry restore failed: #{inspect(reason)}")
    end
  end

  defp move_existing_dest_to_backup(_final_dest, nil), do: :ok

  defp move_existing_dest_to_backup(final_dest, backup_dir) do
    case File.rename(final_dest, backup_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to stage existing skill directory: #{reason}"}
    end
  end

  defp move_staged_into_place(staged_dir, final_dest) do
    case File.rename(staged_dir, final_dest) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to move staged skill into place: #{reason}"}
    end
  end

  defp rollback_activation(%{final_dest: final_dest, backup_dir: backup_dir}) do
    if File.exists?(final_dest) do
      File.rm_rf(final_dest)
    end

    if is_binary(backup_dir) and File.exists?(backup_dir) do
      case File.rename(backup_dir, final_dest) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[Installer] failed to restore backup dir: #{inspect(reason)}")
      end
    end
  end

  defp backup_dir(final_dest) do
    parent = Path.dirname(final_dest)
    name = Path.basename(final_dest)
    Path.join(parent, ".#{name}.backup-#{System.unique_integer([:positive])}")
  end

  defp cleanup_backup_dir(nil), do: :ok

  defp cleanup_backup_dir(backup_dir) do
    if File.exists?(backup_dir) do
      File.rm_rf(backup_dir)
    end
  end

  defp legacy_update(%Entry{source: source_url}) when is_binary(source_url) do
    install(source_url, force: true)
  end

  defp legacy_update(%Entry{}) do
    {:error, "Cannot update: skill has no resolvable source"}
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  defp scope_to_source_atom(:global), do: :global
  defp scope_to_source_atom({:project, _cwd}), do: :project
  defp scope_cwd(:global), do: nil
  defp scope_cwd({:project, cwd}), do: cwd

  defp entry_scope(%Entry{source: :global}, _cwd), do: :global
  defp entry_scope(%Entry{source: :project}, cwd) when is_binary(cwd), do: {:project, cwd}

  defp entry_scope(%Entry{path: path}, nil) do
    # Best-effort: check whether the path lives under the global skills dir.
    if String.starts_with?(path, Config.global_skills_dir()) do
      :global
    else
      # Infer project cwd from path structure: <cwd>/.lemon/skill/<skill-name>
      inferred_cwd = path |> Path.dirname() |> Path.dirname() |> Path.dirname()
      {:project, inferred_cwd}
    end
  end

  defp entry_scope(_, _), do: :global

  defp existing_entry(%InstallPlan{scope: scope, skill_name: key}) do
    opts =
      case scope do
        :global -> []
        {:project, cwd} -> [cwd: cwd]
      end

    case Registry.get(key, opts) do
      {:ok, entry} -> entry
      :error -> nil
    end
  end

  defp stored_install_hash(%Entry{bundle_hash: hash}) when is_binary(hash), do: hash
  defp stored_install_hash(%Entry{content_hash: hash}) when is_binary(hash), do: hash
  defp stored_install_hash(_entry), do: nil

  defp current_install_hash(%Entry{} = entry) do
    case stored_install_hash(entry) do
      nil -> nil
      _ when is_binary(entry.bundle_hash) -> Entry.compute_bundle_hash(entry)
      _ -> Entry.compute_content_hash(entry)
    end
  end

  # ============================================================================
  # Approval gating
  # ============================================================================

  defp request_approval_if_needed(operation, skill_name, source, trust_level, opts) do
    if Keyword.get(opts, :approve, false) or not approvals_enabled?() or
         TrustPolicy.auto_approve?(trust_level) do
      :ok
    else
      ctx = %{
        session_key: Keyword.get(opts, :session_key),
        agent_id: Keyword.get(opts, :agent_id),
        run_id: Keyword.get(opts, :run_id)
      }

      request_skill_approval(operation, skill_name, source, ctx)
    end
  end

  defp approvals_enabled? do
    Application.get_env(:lemon_skills, :require_approval, true)
  end

  defp request_audit_warning_approval_if_needed(operation, entry, source, opts)
       when is_list(opts) do
    if Keyword.get(opts, :approve, false) do
      :ok
    else
      do_request_audit_warning_approval_if_needed(operation, entry, source, opts)
    end
  end

  defp do_request_audit_warning_approval_if_needed(
         _operation,
         %Entry{audit_status: status},
         _source,
         _opts
       )
       when status != :warn do
    :ok
  end

  defp do_request_audit_warning_approval_if_needed(operation, %Entry{} = entry, source, opts) do
    ctx = %{
      session_key: Keyword.get(opts, :session_key),
      agent_id: Keyword.get(opts, :agent_id),
      run_id: Keyword.get(opts, :run_id)
    }

    request_skill_approval(
      operation,
      entry.key,
      source,
      ctx,
      build_audit_warning_rationale(operation, entry, source)
    )
  end

  defp request_skill_approval(operation, skill_name, source, ctx, rationale \\ nil) do
    tool = "skills.#{operation}"

    action = %{operation: operation, skill_name: skill_name, source: source}
    rationale = rationale || build_rationale(operation, skill_name, source)
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

    Logger.info("[Installer] Requesting approval for #{operation} of skill '#{skill_name}'")

    case LemonCore.ExecApprovals.request(params) do
      {:ok, :approved, scope} ->
        Logger.info("[Installer] #{operation} approved at scope #{scope} for '#{skill_name}'")
        :ok

      {:ok, :denied} ->
        Logger.warning("[Installer] #{operation} denied for '#{skill_name}'")
        {:error, "Skill #{operation} denied by user"}

      {:error, :timeout} ->
        Logger.warning("[Installer] #{operation} approval timed out for '#{skill_name}'")
        {:error, "Skill #{operation} approval timed out"}
    end
  rescue
    _ -> {:error, "Approval service unavailable"}
  end

  defp build_rationale(:install, name, source), do: "Install skill '#{name}' from #{source}"
  defp build_rationale(:update, name, _source), do: "Update skill '#{name}' to latest version"
  defp build_rationale(:uninstall, name, _source), do: "Uninstall skill '#{name}'"

  defp build_audit_warning_rationale(operation, %Entry{} = entry, source) do
    findings =
      entry.audit_findings
      |> Enum.take(3)
      |> Enum.join("; ")

    "#{build_rationale(operation, entry.key, source)}. Security audit warnings: #{findings}"
  end
end
