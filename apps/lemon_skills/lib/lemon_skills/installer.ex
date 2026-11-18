defmodule LemonSkills.Installer do
  @moduledoc """
  Skill installation and update management.

  Handles installing skills from various sources using the source abstraction
  layer (`LemonSkills.Source` + `LemonSkills.SourceRouter`).

  ## Installation flow

      resolve → plan → check_existing → approve → fetch_to_staging
        → load_manifest → scan + audit_entry → authorize_audit_result
        → activate → write_lockfile → register

  Bundles are fetched into a private directory under
  `LemonSkills.Config.skill_staging_dir/0`, outside every skill root, so a
  fetched bundle is never discoverable while it waits for audit or approval.
  The staged tree is scanned once by `LemonSkills.Bundle.scan/1`; that scan is
  the audited set. Hidden, out-of-layout, symlinked or special entries block the
  install with a `bundle_layout` finding that no override can lift. Activation
  copies exactly the audited files (each re-verified against its audited
  digest), renames them into place and re-scans the live tree; a live set that
  differs from the audited set rolls the activation back.

  ## Update flow

      lookup → get upstream_hash → compare with current install hash
        → if drifted: fetch_to_staging → load_manifest → scan + audit → activate
          → write_lockfile → register
        → if current: no-op

  ## Approval gating

  Per parity requirement, skill install/update/uninstall operations require
  user approval. Override via `:approve` option or configure globally. An audit
  block is different: it requires a dedicated exact-bundle security approval,
  and ordinary `:approve` never bypasses it.
  """

  alias LemonSkills.{
    Audit.State,
    Bundle,
    Config,
    Entry,
    InstallPlan,
    Lockfile,
    Manifest,
    Registry,
    SkillRoot,
    SourceRouter,
    TrustPolicy
  }

  alias LemonSkills.Audit.{BundleAudit, Engine, Finding}

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
    This does not override an audit block.
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

      with_staged_fetch(plan.source_module, plan.source_id, opts, fn staged_dir ->
        with {:ok, entry} <- load_entry_from_dir(staged_dir, plan),
             {:ok, entry, scan} <- audit_entry(entry, plan.scope, opts),
             {:ok, entry} <- authorize_audit_result(:install, entry, source, opts),
             {:ok, activation} <-
               activate_staged_install(scan, plan.dest_dir, plan.scope, plan.force),
             {:ok, entry} <-
               persist_activated_install(plan.scope, entry, activation, previous_entry) do
          {:ok, entry}
        end
      end)
    end
  end

  @doc """
  Promotes the synthesized draft bundle at `draft_dir` into an installed skill.

  The draft is staged privately and freshly audited (never from a cached
  verdict). Promotion then always requires an explicit `skills.promote`
  approval whose action names the exact audited `bundle_hash`, verdict and
  findings digest; a blocked verdict instead requires the exact-bundle security
  override. Nothing in the draft or its metadata can pre-approve it, and the
  caller's `:approve` option is ignored.

  Accepts the `:global`, `:cwd`, `:force`, `:session_key`, `:agent_id` and
  `:run_id` options of `install/2`.
  """
  @spec promote_draft(String.t(), keyword()) :: install_result()
  def promote_draft(draft_dir, opts \\ []) when is_binary(draft_dir) do
    opts = Keyword.delete(opts, :approve)
    global = Keyword.get(opts, :global, true)
    cwd = Keyword.get(opts, :cwd)

    with {:ok, plan} <- build_plan(draft_dir, global, cwd, opts),
         :ok <- check_existing(plan) do
      previous_entry = existing_entry(plan)

      with_staged_fetch(plan.source_module, plan.source_id, opts, fn staged_dir ->
        with {:ok, entry} <- load_entry_from_dir(staged_dir, plan),
             {:ok, entry, scan} <- audit_entry(entry, plan.scope, Keyword.put(opts, :force, true)),
             {:ok, entry} <- authorize_promotion(entry, draft_dir, opts),
             {:ok, activation} <-
               activate_staged_install(scan, plan.dest_dir, plan.scope, plan.force),
             {:ok, entry} <-
               persist_activated_install(plan.scope, entry, activation, previous_entry) do
          {:ok, entry}
        end
      end)
    end
  end

  defp authorize_promotion(%Entry{audit_status: :block} = entry, source, opts),
    do: authorize_audit_result(:promote, entry, source, opts)

  defp authorize_promotion(%Entry{} = entry, source, opts) do
    ctx = %{
      session_key: Keyword.get(opts, :session_key),
      agent_id: Keyword.get(opts, :agent_id),
      run_id: Keyword.get(opts, :run_id)
    }

    rationale =
      case entry.audit_findings do
        [] -> build_rationale(:promote, entry.key, source)
        _ -> build_audit_warning_rationale(:promote, entry, source)
      end

    case request_skill_approval(:promote, entry.key, source, ctx, rationale,
           tool: "skills.promote",
           action: build_audit_warning_action(:promote, entry, source)
         ) do
      :ok -> {:ok, entry}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs `fun` with a fresh private (0700) directory under
  `Config.skill_staging_dir/0`, outside every skill root, removing it after.
  """
  @spec with_private_staging((String.t() -> result)) :: result | {:error, String.t()}
        when result: term()
  def with_private_staging(fun) when is_function(fun, 1) do
    with {:ok, staging} <- create_staging_dir() do
      try do
        fun.(staging)
      after
        File.rm_rf(staging)
      end
    end
  end

  @doc """
  Activates exactly the files of the audited `scan` as the skill directory
  `dest` of `scope`: each file is copied with its audited digest re-checked,
  the copy is renamed into place and the live set re-verified against the
  scan. An existing `dest` is replaced only when `replace?` is true.
  """
  @spec activate_audited(Bundle.scan(), String.t(), SkillRoot.scope(), boolean()) ::
          :ok | {:error, term()}
  def activate_audited(scan, dest, scope, replace?) do
    with {:ok, activation} <- activate_staged_install(scan, dest, scope, replace?) do
      cleanup_backup_dir(activation)
    end
  end

  defp authorize_audit_result(operation, %Entry{audit_status: :block} = entry, source, opts) do
    if Keyword.get(opts, :approve, false) do
      blocked_audit_error(entry)
    else
      case request_audit_block_override(operation, entry, source, opts) do
        :ok -> {:ok, %{entry | audit_status: :overridden}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp authorize_audit_result(operation, %Entry{audit_status: :warn} = entry, source, opts) do
    case request_audit_warning_approval_if_needed(operation, entry, source, opts) do
      :ok -> {:ok, entry}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_audit_result(_operation, %Entry{} = entry, _source, _opts), do: {:ok, entry}

  defp blocked_audit_error(%Entry{audit_findings: findings}) do
    reason =
      findings
      |> Enum.take(3)
      |> Enum.join("; ")

    {:error, "Skill blocked by security audit: #{reason}"}
  end

  @doc """
  Imports a skill bundle that was staged outside every skill root by an offline
  migration (no running Registry or approval service).

  The staged bundle is scanned once and that exact scan gets the static audit
  (`LemonSkills.Audit.Engine.audit_scan/1`). A bundle with layout violations or
  a `:block` verdict is refused. Otherwise exactly the audited files are
  activated into `<agent_dir>/skill/<key>` (copied with digest checks, renamed
  into place, live tree re-verified) and recorded in `<agent_dir>`'s lockfile
  with `trust_level: :community` and `audit_status: :pending`, so the runtime
  audit and approval pipeline still judges the skill before trusting it.

  ## Options

  - `:agent_dir` — target agent directory (required)
  - `:key` — installed skill directory name (required)
  - `:source_kind` — provenance (default `:hermes`)
  - `:force` — replace an existing skill directory (default `false`)

  Returns `{:ok, entry, {verdict, findings}}`, `{:error, {:blocked, findings}}`
  or `{:error, reason}`.
  """
  @spec import_bundle(String.t(), keyword()) ::
          {:ok, Entry.t(), {atom(), [String.t()]}}
          | {:error, {:blocked, [String.t()]}}
          | {:error, term()}
  def import_bundle(staged_dir, opts) when is_binary(staged_dir) do
    agent_dir = Path.expand(Keyword.fetch!(opts, :agent_dir))
    key = Keyword.fetch!(opts, :key)
    root = Path.join(agent_dir, "skill")
    dest = Path.join(root, key)

    with :ok <- validate_import_key(key),
         {:ok, scan} <- scan_staged(staged_dir),
         {verdict, findings} = Engine.audit_scan(scan),
         summaries = Enum.map(findings, &Finding.summary/1),
         :ok <- import_verdict(verdict, scan, summaries),
         {:ok, entry} <- load_import_entry(staged_dir, key, scan, opts),
         :ok <- import_root(agent_dir, root),
         {:ok, activation} <- activate(scan, dest, root, Keyword.get(opts, :force, false)) do
      entry = %{entry | path: dest, audit_findings: summaries}

      case write_lockfile({:agent_dir, agent_dir}, entry) do
        :ok ->
          cleanup_backup_dir(activation)

          Logger.info(
            "[Installer] imported '#{key}' (#{entry.source_kind}) audit=#{verdict} recorded=pending"
          )

          {:ok, entry, {verdict, summaries}}

        {:error, _reason} = error ->
          rollback_activation(activation)
          error
      end
    end
  end

  defp validate_import_key(key) do
    if is_binary(key) and key not in ["", ".", ".."] and not String.starts_with?(key, ".") and
         Path.basename(key) == key do
      :ok
    else
      {:error, "Invalid skill name #{inspect(key)}"}
    end
  end

  defp import_verdict(:block, _scan, summaries), do: {:error, {:blocked, summaries}}
  defp import_verdict(_verdict, %{violations: []}, _summaries), do: :ok
  defp import_verdict(_verdict, _scan, summaries), do: {:error, {:blocked, summaries}}

  defp load_import_entry(staged_dir, key, scan, opts) do
    entry =
      Entry.new(staged_dir,
        source: :global,
        source_kind: Keyword.get(opts, :source_kind, :hermes),
        trust_level: :community,
        audit_status: :pending,
        installed_at: DateTime.utc_now()
      )
      |> Map.put(:key, key)

    with {:ok, content} <- Entry.content(entry),
         {:ok, manifest, _body} <- Manifest.parse_and_validate(content) do
      entry = Entry.with_manifest(entry, manifest)

      {:ok,
       %{entry | content_hash: Entry.compute_content_hash(entry), bundle_hash: Bundle.hash(scan)}}
    else
      {:error, reason} -> {:error, "Invalid SKILL.md: #{inspect(reason)}"}
    end
  end

  # The agent dir is the trusted anchor (see `SkillRoot.trusted_dir/1`): a real,
  # user-owned directory, and every component from it down to the skill root
  # must be a real directory.
  defp import_root(agent_dir, root) do
    with {:ok, anchor} <- SkillRoot.trusted_dir(agent_dir),
         :ok <- SkillRoot.ensure_dir(anchor, root) do
      :ok
    else
      _ -> {:error, "Unsafe skill directory #{root}"}
    end
  end

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
        # Trust is always derived from the source module; the lockfile's stored
        # trust level is descriptive only and never gates approval or audit.
        source = resolve_update_source(entry)

        trust =
          case source do
            {:ok, mod, id} -> mod.trust_for_ref(id)
            :no_source -> nil
          end

        with :ok <- request_approval_if_needed(:update, key, entry.path, trust, opts) do
          update_entry(entry, source, force, cwd, opts)
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
               request_approval_if_needed(:uninstall, key, entry.path, gate_trust(entry), opts) do
          scope = entry_scope(entry, cwd)

          with {:ok, _root, anchor} <- contained_skill_dir(entry.path, scope),
               :ok <- SkillRoot.remove(anchor, entry.path) do
            Lockfile.delete(scope, key)
            State.delete(scope, :skill, key)
            Registry.unregister(key, entry.source, cwd)
            :ok
          else
            {:error, reason} when is_binary(reason) -> {:error, reason}
            {:error, reason} -> {:error, "Failed to remove skill directory: #{inspect(reason)}"}
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
         scope = if(global, do: :global, else: {:project, cwd}),
         :ok <- ensure_parent_dir(dest_dir, scope) do
      source_kind = SourceRouter.source_kind(mod)

      trust_level = mod.trust_for_ref(id)

      force = Keyword.get(opts, :force, false)

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

    if name in ["", ".", ".."] or String.starts_with?(name, ".") or
         Regex.match?(~r/[\x00-\x1f\x7f\\:]/, name) do
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

  # Creates the skill root under its trusted anchor, refusing any symlinked
  # component (a repo can make `.lemon/skill` a link to anywhere, and the global
  # root is anchored at the validated agent dir).
  defp ensure_parent_dir(dest_dir, scope) do
    root = Path.dirname(dest_dir)

    with {:ok, root, anchor} <- SkillRoot.resolve_root(root, scope),
         :ok <- SkillRoot.ensure_dir(anchor, root) do
      :ok
    else
      {:error, reason} -> {:error, "Unsafe skill directory #{root}: #{inspect(reason)}"}
    end
  end

  # Resolves the configured root holding `path` and re-checks its parent chain
  # against the trusted anchor before any rename or removal.
  defp contained_skill_dir(path, scope) do
    with {:ok, root, anchor} <- SkillRoot.locate(path, scope),
         :ok <- SkillRoot.check_dir(anchor, root) do
      {:ok, root, anchor}
    else
      {:error, reason} -> {:error, "Unsafe skill directory #{path}: #{inspect(reason)}"}
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

  # Fetches into a private directory under `Config.skill_staging_dir/0`, outside
  # every skill root, so nothing fetched is discoverable before activation.
  defp with_staged_fetch(source_module, source_id, opts, fun) when is_function(fun, 1) do
    with_private_staging(fn staging ->
      case source_module.fetch(source_id, Path.join(staging, "bundle"), opts) do
        {:ok, fetched_dir} -> fun.(fetched_dir)
        {:error, {:bundle_violations, violations}} -> layout_blocked_error(violations)
        {:error, _reason} = error -> error
      end
    end)
  end

  defp create_staging_dir do
    root = Config.skill_staging_dir()
    dir = Path.join(root, "#{System.os_time(:second)}-#{System.unique_integer([:positive])}")

    with {:ok, anchor} <- SkillRoot.trusted_dir(Config.agent_dir()),
         :ok <- SkillRoot.ensure_dir(anchor, root),
         :ok <- File.chmod(root, 0o700),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      _ -> {:error, "Failed to create a private skill staging directory"}
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

    case Entry.content(entry) do
      {:ok, content} ->
        case Manifest.parse_and_validate(content) do
          {:ok, manifest, _body} ->
            entry =
              entry
              |> Entry.with_manifest(manifest)
              |> Map.put(:content_hash, Entry.compute_content_hash(entry))
              |> Map.put(:bundle_hash, nil)

            {:ok, entry}

          {:error, reason} ->
            {:error, "Invalid SKILL.md manifest: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to read SKILL.md after install: #{reason}"}
    end
  end

  # Scans the staged bundle once, audits that exact scan and returns it: the
  # scan is the audited set and the only set `activate_staged_install/3` copies.
  # Layout violations block outright; no override can activate them.
  defp audit_entry(%Entry{trust_level: trust_level} = entry, scope, opts) do
    with {:ok, scan} <- scan_staged(entry.path) do
      bundle_hash = Bundle.hash(scan)

      if TrustPolicy.requires_audit?(trust_level) do
        with {:ok, result} <-
               BundleAudit.audit(entry.path, scope, entry.key, Keyword.put(opts, :kind, :skill)),
             :ok <- require_audited_bundle(result["bundle_hash"], bundle_hash),
             :ok <- reject_layout_violations(scan) do
          {:ok,
           %{
             entry
             | bundle_hash: bundle_hash,
               audit_status: BundleAudit.audit_status(result),
               audit_findings: BundleAudit.audit_findings(result)
           }, scan}
        end
      else
        with :ok <- reject_layout_violations(scan) do
          {:ok, %{entry | bundle_hash: bundle_hash, audit_status: :pass, audit_findings: []},
           scan}
        end
      end
    end
  end

  defp scan_staged(path) do
    case Bundle.scan(path) do
      {:ok, scan} -> {:ok, scan}
      {:error, reason} -> {:error, "Failed to scan staged skill bundle: #{inspect(reason)}"}
    end
  end

  defp require_audited_bundle(hash, hash) when is_binary(hash), do: :ok

  defp require_audited_bundle(_audited, _scanned),
    do: {:error, "Skill bundle changed during audit"}

  defp reject_layout_violations(%{violations: []}), do: :ok
  defp reject_layout_violations(%{violations: violations}), do: layout_blocked_error(violations)

  defp layout_blocked_error(violations) do
    findings =
      violations
      |> Enum.take(5)
      |> Enum.map_join("; ", &("bundle_layout: " <> Bundle.describe_violation(&1)))

    {:error, "Skill blocked by security audit: #{findings}"}
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

  # Copies exactly the audited files (each re-verified against its audited
  # digest) into a dot-named activation dir beside the destination, renames it
  # into place and re-scans the live tree: the activated set must equal the
  # audited set or the activation is rolled back. The destination's root chain
  # is re-checked against its trusted anchor first, so a symlinked root can
  # never redirect the rename, backup or removal outside the skill root.
  defp activate_staged_install(scan, final_dest, scope, force) do
    with {:ok, _root, anchor} <- contained_skill_dir(final_dest, scope) do
      activate(scan, final_dest, anchor, force)
    end
  end

  # `anchor` must already be checked as the trusted anchor of `final_dest`'s root.
  defp activate(scan, final_dest, anchor, force) do
    if File.exists?(final_dest) and not force do
      {:error, "Skill destination already exists at #{final_dest}"}
    else
      activation_dir =
        Path.join(
          Path.dirname(final_dest),
          ".#{Path.basename(final_dest)}.activate-#{System.unique_integer([:positive])}"
        )

      with :ok <- copy_audited_files(scan, activation_dir),
           :ok <- verify_activated_set(activation_dir, scan) do
        backup_dir = if File.exists?(final_dest), do: backup_dir(final_dest)

        with :ok <- move_existing_dest_to_backup(final_dest, backup_dir) do
          activation = %{final_dest: final_dest, backup_dir: backup_dir, anchor: anchor}

          with :ok <- move_staged_into_place(activation_dir, final_dest),
               :ok <- verify_activated_set(final_dest, scan) do
            {:ok, activation}
          else
            {:error, reason} = error ->
              rollback_activation(activation)

              Logger.warning(
                "[Installer] activation failed for '#{final_dest}': #{inspect(reason)}"
              )

              error
          end
        end
      end
      |> tap(fn _ -> SkillRoot.remove(anchor, activation_dir) end)
    end
  end

  defp copy_audited_files(scan, activation_dir) do
    case Bundle.copy_files(scan, activation_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Skill bundle changed after audit: #{inspect(reason)}"}
    end
  end

  defp verify_activated_set(dir, audited) do
    case Bundle.scan(dir) do
      {:ok, %{violations: []} = live} ->
        if Bundle.manifest(live) == Bundle.manifest(audited),
          do: :ok,
          else: {:error, "Activated skill files differ from the audited set"}

      _ ->
        {:error, "Activated skill files differ from the audited set"}
    end
  end

  # The operator-side load grant is bound to the exact activated bundle hash;
  # offline imports (`import_bundle/2`) never call this and stay ungranted.
  defp persist_activated_install(scope, entry, activation, previous_entry) do
    live_entry = %{entry | path: activation.final_dest, authorized_hash: entry.bundle_hash}

    with :ok <-
           State.authorize(scope, live_entry.key, live_entry.bundle_hash, live_entry.audit_status),
         :ok <- persist_entry_metadata(scope, live_entry, previous_entry) do
      cleanup_backup_dir(activation)
      {:ok, live_entry}
    else
      {:error, reason} ->
        rollback_activation(activation)
        {:error, reason}
    end
  end

  # ============================================================================
  # Update logic
  # ============================================================================

  # A lockfile `builtin` claim gates nothing unless the installed bytes equal
  # the bundle shipped in this release.
  defp gate_trust(%Entry{trust_level: :builtin} = entry) do
    if LemonSkills.Sources.Builtin.verified_install?(entry), do: :builtin, else: nil
  end

  defp gate_trust(%Entry{trust_level: trust}), do: trust

  defp update_entry(entry, source, force, cwd, opts) do
    case source do
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

    with_staged_fetch(mod, id, build_plan_opts, fn staged_dir ->
      with {:ok, updated_entry} <-
             load_entry_from_dir(staged_dir, %InstallPlan{
               source_module: mod,
               source_id: id,
               source_kind: SourceRouter.source_kind(mod),
               trust_level: mod.trust_for_ref(id),
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
           {:ok, updated_entry, scan} <- audit_entry(updated_entry, scope, opts),
           {:ok, updated_entry} <- authorize_audit_result(:update, updated_entry, id, opts),
           {:ok, activation} <- activate_staged_install(scan, entry.path, scope, true),
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

  @staging_max_age_seconds 3_600
  @activation_leftover ~r/\A\..+\.(staging|activate)-\d+\z/

  @doc """
  Removes install leftovers at boot.

  Deletes staging entries older than an hour from `Config.skill_staging_dir/0`
  and every `.<name>.staging-<n>` / `.<name>.activate-<n>` directory left in
  the global skills directory by an interrupted install, so a crashed install
  is neither discovered nor migrated. Never follows symlinks.
  """
  @spec sweep_staging() :: :ok
  def sweep_staging do
    cutoff = System.os_time(:second) - @staging_max_age_seconds
    staging_root = Config.skill_staging_dir()

    with {:ok, anchor} <- SkillRoot.trusted_dir(Config.agent_dir()) do
      if SkillRoot.check_dir(anchor, staging_root) == :ok do
        for name <- ls_or_empty(staging_root),
            path = Path.join(staging_root, name),
            {:ok, %File.Stat{mtime: mtime}} <- [File.lstat(path, time: :posix)],
            mtime < cutoff do
          SkillRoot.remove(anchor, path)
        end
      end

      skills_root = Config.global_skills_dir()

      if SkillRoot.check_dir(anchor, skills_root) == :ok do
        for name <- ls_or_empty(skills_root),
            Regex.match?(@activation_leftover, name) do
          Logger.info("[Installer] removing interrupted install leftover #{name}")
          SkillRoot.remove(anchor, Path.join(skills_root, name))
        end
      end
    end

    :ok
  end

  defp ls_or_empty(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
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

  defp rollback_activation(%{final_dest: final_dest, backup_dir: backup_dir, anchor: anchor}) do
    _ = SkillRoot.remove(anchor, final_dest)

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

  defp cleanup_backup_dir(%{backup_dir: nil}), do: :ok

  defp cleanup_backup_dir(%{backup_dir: backup_dir, anchor: anchor}) do
    _ = SkillRoot.remove(anchor, backup_dir)
    :ok
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
      build_audit_warning_rationale(operation, entry, source),
      tool: "skills.#{operation}.audit_warning",
      action: build_audit_warning_action(operation, entry, source),
      denied_reason: "Skill #{operation} audit warning denied by user",
      timeout_reason: "Skill #{operation} audit warning approval timed out"
    )
  end

  # The warning approval is its own identity, bound to the exact audited bundle
  # and a digest of every finding: a grant for `skills.<op>` or for another
  # bundle never approves this warning.
  defp build_audit_warning_action(operation, %Entry{} = entry, source) do
    %{
      operation: operation,
      skill_name: entry.key,
      source: source,
      audit_status: :warn,
      bundle_hash: entry.bundle_hash,
      findings_digest:
        :crypto.hash(:sha256, Enum.join(entry.audit_findings, "\n"))
        |> Base.encode16(case: :lower),
      findings: Enum.take(entry.audit_findings, 3)
    }
  end

  defp request_audit_block_override(operation, %Entry{} = entry, source, opts) do
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
      build_audit_block_rationale(operation, entry, source),
      tool: "skills.#{operation}.security_override",
      action: build_audit_block_action(operation, entry, source),
      denied_reason: "Skill #{operation} security override denied by user",
      timeout_reason: "Skill #{operation} security override approval timed out",
      unavailable_reason: "Security override approval service unavailable"
    )
  end

  defp request_skill_approval(
         operation,
         skill_name,
         source,
         ctx,
         rationale \\ nil,
         request_opts \\ []
       ) do
    tool = Keyword.get(request_opts, :tool, "skills.#{operation}")

    action =
      Keyword.get(request_opts, :action, %{
        operation: operation,
        skill_name: skill_name,
        source: source
      })

    rationale = rationale || build_rationale(operation, skill_name, source)
    timeout_ms = Application.get_env(:lemon_skills, :approval_timeout_ms, 300_000)

    denied_reason =
      Keyword.get(request_opts, :denied_reason, "Skill #{operation} denied by user")

    timeout_reason =
      Keyword.get(request_opts, :timeout_reason, "Skill #{operation} approval timed out")

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
        {:error, denied_reason}

      {:error, :timeout} ->
        Logger.warning("[Installer] #{operation} approval timed out for '#{skill_name}'")
        {:error, timeout_reason}
    end
  rescue
    _ ->
      {:error, Keyword.get(request_opts, :unavailable_reason, "Approval service unavailable")}
  end

  defp build_rationale(:install, name, source), do: "Install skill '#{name}' from #{source}"
  defp build_rationale(:update, name, _source), do: "Update skill '#{name}' to latest version"
  defp build_rationale(:uninstall, name, _source), do: "Uninstall skill '#{name}'"

  defp build_rationale(:promote, name, source),
    do: "Publish synthesized draft '#{name}' from #{source} as an installed skill"

  defp build_audit_warning_rationale(operation, %Entry{} = entry, source) do
    findings =
      entry.audit_findings
      |> Enum.take(3)
      |> Enum.join("; ")

    "#{build_rationale(operation, entry.key, source)}. Security audit warnings: #{findings}"
  end

  defp build_audit_block_action(operation, %Entry{} = entry, source) do
    %{
      operation: operation,
      skill_name: entry.key,
      source: source,
      description:
        "Override BLOCKED security audit for '#{entry.key}' bundle #{short_hash(entry.bundle_hash)}",
      security_override: true,
      audit_status: :block,
      bundle_hash: entry.bundle_hash,
      findings: Enum.take(entry.audit_findings, 3)
    }
  end

  defp build_audit_block_rationale(operation, %Entry{} = entry, source) do
    findings = entry.audit_findings |> Enum.take(3) |> Enum.join("; ")

    "SECURITY WARNING: #{build_rationale(operation, entry.key, source)} was blocked by the audit. " <>
      "Approving this override permits potentially dangerous instructions from this exact bundle " <>
      "(#{short_hash(entry.bundle_hash)}). Findings: #{findings}"
  end

  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp short_hash(_hash), do: "unknown"
end
