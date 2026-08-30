defmodule LemonAutomation.Blueprint do
  @moduledoc """
  Safe, confirmed activation for portable skill and automation bundles.

  A bundle is a directory containing `bundle.json` and one or more audited
  skill directories under `skills/`. Activation copies those skills into the
  target profile's derived project-skill boundary and creates exactly one
  agent-backed cron job through `CronManager`. It does not introduce another
  skill registry, profile store, or scheduler.

  Preview is mandatory. The returned confirmation digest covers the normalized
  manifest, skill content hashes, target profile, exact cron definition, and
  the current destination/job state. Activation re-plans under a lock and
  rejects a stale digest before any write.

  Version 1 deliberately excludes command jobs, environment injection,
  arbitrary working directories, archives, symlinks, and overwrite semantics.
  """

  import Kernel, except: [inspect: 1]

  alias LemonAutomation.{CronJob, CronManager, CronSchedule, CronStore}
  alias LemonCore.ProfileStore
  alias LemonSkills.Audit.{Engine, SkillLint}
  alias LemonSkills.{Bundle, Config, Manifest}

  @format "lemon-skill-automation-bundle"
  @version 1
  @manifest_file "bundle.json"
  @max_manifest_bytes 131_072
  @max_bundles 64
  @max_skills 16
  @max_automations 1
  @max_files 256
  @max_file_bytes 1_048_576
  @max_total_bytes 8_388_608
  @max_prompt_bytes 8_192
  @allowed_skill_root_entries ~w(SKILL.md references templates scripts assets)
  @archive_extensions ~w(.7z .bz2 .gz .jar .rar .tar .tgz .war .xz .zip)
  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @control_regex ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u
  @bidi_regex ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @secret_key_regex ~r/(?:api[_-]?key|authorization|bearer|credential|master[_-]?key|oauth|password|private[_-]?key|secret|session[_-]?token|token|wallet[_-]?key)/i
  @secret_value_regexes [
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/,
    ~r/\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{8,}\b/i,
    ~r/\bxox[a-z]-[A-Za-z0-9-]{8,}\b/i,
    ~r/\bAKIA[A-Z0-9]{16}\b/,
    ~r/\bBearer\s+[A-Za-z0-9._~-]{8,}\b/i,
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/
  ]

  @type safe_error :: {atom(), String.t()}

  @doc "Return the supported portable manifest format and version."
  @spec format() :: map()
  def format, do: %{"format" => @format, "version" => @version}

  @doc "List bounded bundle summaries directly below a catalog directory."
  @spec list(String.t()) :: {:ok, map()} | {:error, safe_error()}
  def list(root) when is_binary(root) do
    with {:ok, root} <- require_directory(root, :invalid_catalog),
         {:ok, names} <- File.ls(root) |> map_file_error(:catalog_unreadable) do
      {bundles, invalid_count, truncated} =
        names
        |> Enum.sort()
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.take(@max_bundles + 1)
        |> Enum.reduce({[], 0, false}, fn name, {valid, invalid, was_truncated} ->
          if length(valid) + invalid >= @max_bundles do
            {valid, invalid, true}
          else
            path = Path.join(root, name)

            case File.lstat(path) do
              {:ok, %File.Stat{type: :directory}} ->
                case inspect(path) do
                  {:ok, summary} -> {[summary | valid], invalid, was_truncated}
                  {:error, _} -> {valid, invalid + 1, was_truncated}
                end

              _ ->
                {valid, invalid, was_truncated}
            end
          end
        end)

      bundles = Enum.sort_by(bundles, &{String.downcase(&1["name"]), &1["id"]})

      {:ok,
       %{
         "bundles" => bundles,
         "summary" => %{
           "bundleCount" => length(bundles),
           "invalidBundleCount" => invalid_count,
           "truncated" => truncated,
           "pathsReturned" => false,
           "secretValuesReturned" => false
         }
       }}
    end
  end

  def list(_), do: error(:invalid_catalog, "Bundle catalog must be a directory")

  @doc "Inspect a bundle through the same validation and audit path used by activation."
  @spec inspect(String.t()) :: {:ok, map()} | {:error, safe_error()}
  def inspect(path) when is_binary(path) do
    with {:ok, bundle} <- load(path) do
      {:ok, public_bundle(bundle, false)}
    end
  end

  def inspect(_), do: error(:invalid_bundle, "Bundle path must be a directory or bundle.json")

  @doc "Validate a bundle and return a content-free security/provenance report."
  @spec validate(String.t()) :: {:ok, map()} | {:error, safe_error()}
  def validate(path) when is_binary(path) do
    with {:ok, bundle} <- load(path) do
      {:ok, public_bundle(bundle, true)}
    end
  end

  def validate(_), do: error(:invalid_bundle, "Bundle path must be a directory or bundle.json")

  @doc "Preview exact profile-skill and cron actions without mutation."
  @spec preview(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, safe_error()}
  def preview(path, profile_id, opts \\ [])

  def preview(path, profile_id, opts) when is_binary(path) and is_binary(profile_id) do
    with {:ok, state} <- build_plan(path, profile_id, opts) do
      {:ok, state.public_plan}
    end
  end

  def preview(_, _, _), do: error(:invalid_request, "Bundle path and profile ID are required")

  @doc "Activate a freshly previewed plan after exact digest confirmation."
  @spec activate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, safe_error()}
  def activate(path, profile_id, confirmation_digest, opts \\ [])

  def activate(path, profile_id, confirmation_digest, opts)
      when is_binary(path) and is_binary(profile_id) and is_binary(confirmation_digest) do
    lock = {__MODULE__, Path.expand(path) <> "\0" <> profile_id}

    :global.trans(lock, fn ->
      with {:ok, state} <- build_plan(path, profile_id, opts),
           :ok <- require_activatable(state.public_plan),
           :ok <- verify_confirmation(state.public_plan, confirmation_digest),
           {:ok, skill_result, rollback} <- apply_skills(state, opts),
           {:ok, automation_result} <- apply_automation(state, rollback) do
        {:ok,
         %{
           "activated" => true,
           "bundleId" => state.bundle.id,
           "profileId" => state.profile["id"],
           "confirmationDigest" => state.public_plan["confirmationDigest"],
           "skills" => skill_result,
           "automation" => automation_result,
           "summary" => activation_summary(skill_result, automation_result)
         }}
      end
    end)
  end

  def activate(_, _, _, _), do: error(:invalid_request, "Activation parameters are invalid")

  defp build_plan(path, profile_id, opts) do
    with {:ok, bundle} <- load(path),
         {:ok, profile} <- profile_get(profile_id, opts),
         {:ok, skill_actions} <- plan_skills(bundle, profile),
         {:ok, desired_job} <- desired_job(bundle, profile) do
      definition = definition_projection(bundle, profile, desired_job)
      definition_digest = digest(definition)
      desired_job = put_in(desired_job[:meta]["blueprint"]["definitionDigest"], definition_digest)
      {:ok, automation_action} = plan_automation(desired_job)

      plan_base = %{
        "format" => @format,
        "version" => @version,
        "bundleId" => bundle.id,
        "manifestDigest" => bundle.manifest_digest,
        "definitionDigest" => definition_digest,
        "profile" => %{
          "id" => profile["id"],
          "canonicalSessionKey" => profile["canonicalSessionKey"],
          "workspaceBoundary" => "derived-profile-workspace"
        },
        "skills" => Enum.map(skill_actions, &public_skill_action/1),
        "automation" => public_automation_action(automation_action, desired_job),
        "commandPolicy" => %{
          "mode" => "agent-only",
          "commandsAllowed" => false,
          "environmentOverridesAllowed" => false,
          "workingDirectoryOverridesAllowed" => false
        },
        "canActivate" =>
          Enum.all?(skill_actions, &(&1.action != :collision)) and
            automation_action.action != :collision,
        "cleanup" => %{
          "includesPromptText" => false,
          "includesSkillText" => false,
          "includesSecretValues" => false,
          "includesAbsolutePaths" => false
        }
      }

      confirmation_digest = digest(plan_base)
      public_plan = Map.put(plan_base, "confirmationDigest", confirmation_digest)

      {:ok,
       %{
         bundle: bundle,
         profile: profile,
         skill_actions: skill_actions,
         desired_job: desired_job,
         automation_action: automation_action,
         public_plan: public_plan
       }}
    end
  end

  defp load(path) do
    with {:ok, root, manifest_path} <- resolve_bundle_path(path),
         {:ok, bytes} <- read_manifest(manifest_path),
         {:ok, raw} <- decode_manifest(bytes),
         :ok <- validate_top_level(raw),
         :ok <- reject_secret_manifest_values(raw),
         {:ok, identity} <- validate_identity(raw),
         {:ok, skills} <- validate_skills(root, raw["skills"]),
         {:ok, automations} <- validate_automations(raw["automations"]) do
      normalized = %{
        "format" => @format,
        "version" => @version,
        "id" => identity.id,
        "name" => identity.name,
        "description" => identity.description,
        "skills" => Enum.map(skills, & &1.manifest_projection),
        "automations" => Enum.map(automations, & &1.projection)
      }

      {:ok,
       %{
         root: root,
         id: identity.id,
         name: identity.name,
         description: identity.description,
         skills: skills,
         automations: automations,
         manifest_digest: digest(normalized)
       }}
    end
  end

  defp resolve_bundle_path(path) do
    expanded = Path.expand(path)
    archive? = archive_extension?(expanded)

    cond do
      archive? ->
        error(
          :archive_not_supported,
          "Archive bundles are not supported; use an unpacked directory"
        )

      Path.basename(expanded) == @manifest_file ->
        root = Path.dirname(expanded)

        with {:ok, root} <- require_directory(root, :invalid_bundle),
             :ok <- require_regular_file(expanded, :invalid_manifest) do
          {:ok, root, expanded}
        end

      true ->
        with {:ok, root} <- require_directory(expanded, :invalid_bundle),
             manifest = Path.join(root, @manifest_file),
             :ok <- require_regular_file(manifest, :invalid_manifest) do
          {:ok, root, manifest}
        end
    end
  end

  defp read_manifest(path) do
    with {:ok, %File.Stat{size: size}} <- File.lstat(path) |> map_file_error(:manifest_unreadable),
         true <-
           size <= @max_manifest_bytes ||
             error(:manifest_too_large, "Bundle manifest exceeds the byte limit"),
         {:ok, bytes} <- File.read(path) |> map_file_error(:manifest_unreadable) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_manifest(bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> error(:invalid_manifest, "Bundle manifest must be a JSON object")
    end
  end

  defp validate_top_level(raw) do
    allowed = MapSet.new(~w(format version id name description skills automations))
    unknown = raw |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)

    cond do
      MapSet.size(unknown) > 0 ->
        error(:unsupported_fields, "Bundle manifest contains unsupported fields")

      raw["format"] != @format ->
        error(:unsupported_format, "Bundle manifest format is unsupported")

      raw["version"] != @version ->
        error(:unsupported_version, "Bundle manifest version is unsupported")

      true ->
        :ok
    end
  end

  defp validate_identity(raw) do
    with {:ok, id} <- validate_id(raw["id"], :bundle_id),
         {:ok, name} <- safe_text(raw["name"], :bundle_name, 256, false),
         {:ok, description} <- optional_safe_text(raw["description"], :description, 2_048) do
      {:ok, %{id: id, name: name, description: description}}
    end
  end

  defp validate_skills(_root, skills) when not is_list(skills),
    do: error(:invalid_skills, "Bundle skills must be a list")

  defp validate_skills(root, skills) do
    cond do
      skills == [] ->
        error(:invalid_skills, "Bundle must contain at least one skill")

      length(skills) > @max_skills ->
        error(:bundle_limit_exceeded, "Bundle contains too many skills")

      true ->
        skills
        |> Enum.reduce_while({:ok, [], %{files: 0, bytes: 0, keys: MapSet.new()}}, fn raw,
                                                                                      {:ok, acc,
                                                                                       totals} ->
          case validate_skill(root, raw, totals) do
            {:ok, skill, next_totals} -> {:cont, {:ok, [skill | acc], next_totals}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, result, _totals} -> {:ok, Enum.reverse(result)}
          {:error, _} = error -> error
        end
    end
  end

  defp validate_skill(_root, raw, _totals) when not is_map(raw),
    do: error(:invalid_skill, "Each skill entry must be an object")

  defp validate_skill(root, raw, totals) do
    allowed = MapSet.new(~w(key path))
    unknown = raw |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)

    with true <-
           MapSet.size(unknown) == 0 ||
             error(:unsupported_fields, "Skill entry contains unsupported fields"),
         {:ok, key} <- validate_id(raw["key"], :skill_key),
         true <-
           not MapSet.member?(totals.keys, key) ||
             error(:duplicate_skill, "Bundle skill keys must be unique"),
         expected_path = "skills/#{key}",
         true <-
           raw["path"] == expected_path ||
             error(:invalid_skill_path, "Skill path must use the portable skills/<key> layout"),
         full_path = Path.join(root, expected_path),
         {:ok, full_path} <- require_directory(full_path, :invalid_skill_path),
         {:ok, stats} <- scan_skill_tree(full_path),
         true <-
           totals.files + stats.files <= @max_files ||
             error(:bundle_limit_exceeded, "Bundle contains too many files"),
         true <-
           totals.bytes + stats.bytes <= @max_total_bytes ||
             error(:bundle_limit_exceeded, "Bundle exceeds the total byte limit"),
         {:ok, bundle_hash} <- Bundle.compute_hash(full_path) |> map_bundle_error(),
         :ok <- validate_skill_manifest(full_path),
         :ok <- require_clean_audit(full_path) do
      manifest_projection = %{
        "key" => key,
        "path" => expected_path,
        "bundleHash" => bundle_hash,
        "fileCount" => stats.files,
        "bytes" => stats.bytes,
        "sourceKind" => "portable_bundle",
        "trustLevel" => "untrusted",
        "auditStatus" => "pass"
      }

      next_totals = %{
        files: totals.files + stats.files,
        bytes: totals.bytes + stats.bytes,
        keys: MapSet.put(totals.keys, key)
      }

      {:ok,
       %{
         key: key,
         path: full_path,
         bundle_hash: bundle_hash,
         files: stats.file_entries,
         file_count: stats.files,
         bytes: stats.bytes,
         manifest_projection: manifest_projection
       }, next_totals}
    else
      {:error, _} = error -> error
      false -> error(:duplicate_skill, "Bundle skill keys must be unique")
    end
  end

  defp validate_skill_manifest(path) do
    skill_file = Path.join(path, "SKILL.md")

    with {:ok, bytes} <- File.read(skill_file) |> map_file_error(:invalid_skill),
         {:ok, _manifest, body} <- Manifest.parse_and_validate(bytes) |> map_manifest_error(),
         true <- String.trim(body) != "" || error(:invalid_skill, "Skill body must not be empty"),
         lint = SkillLint.lint_skill(path, include_audit: false),
         true <-
           lint.valid? || error(:invalid_skill, "Skill manifest or layout failed validation") do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp require_clean_audit(path) do
    case Engine.audit_bundle(path) do
      {:pass, []} ->
        :ok

      {:pass, _} ->
        :ok

      {:warn, _} ->
        error(
          :skill_audit_warning,
          "Skill audit warnings are not activatable in bundle version 1"
        )

      {:block, _} ->
        error(:skill_audit_blocked, "Skill audit blocked this bundle")
    end
  end

  defp validate_automations(automations) when not is_list(automations),
    do: error(:invalid_automations, "Bundle automations must be a list")

  defp validate_automations(automations) do
    cond do
      automations == [] ->
        error(:invalid_automations, "Bundle must contain one automation blueprint")

      length(automations) > @max_automations ->
        error(:bundle_limit_exceeded, "Bundle version 1 supports exactly one automation")

      true ->
        automations
        |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
          case validate_automation(raw) do
            {:ok, automation} -> {:cont, {:ok, [automation | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, result} -> {:ok, Enum.reverse(result)}
          {:error, _} = error -> error
        end
    end
  end

  defp validate_automation(raw) when not is_map(raw),
    do: error(:invalid_automation, "Automation blueprint must be an object")

  defp validate_automation(raw) do
    forbidden = ~w(command cwd env environment shell script contextFrom memoryFile)

    allowed =
      MapSet.new(
        ~w(id kind name schedule prompt enabled timezone jitterSec timeoutMs maxRetries retryBackoffMs monitor monitorNotifyFirstRun)
      )

    unknown = raw |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)

    cond do
      Enum.any?(forbidden, &Map.has_key?(raw, &1)) ->
        error(
          :command_policy_violation,
          "Bundle automations are agent-only and cannot declare command execution fields"
        )

      MapSet.size(unknown) > 0 ->
        error(:unsupported_fields, "Automation blueprint contains unsupported fields")

      raw["kind"] != "cron" ->
        error(
          :unsupported_automation_kind,
          "Bundle version 1 supports agent cron blueprints only"
        )

      true ->
        with {:ok, id} <- validate_id(raw["id"], :automation_id),
             {:ok, name} <- safe_text(raw["name"], :automation_name, 256, false),
             {:ok, prompt} <- safe_text(raw["prompt"], :prompt, @max_prompt_bytes, true),
             :ok <- reject_secret_value(prompt),
             {:ok, schedule} <- normalize_schedule(raw["schedule"]),
             {:ok, enabled} <- optional_boolean(raw, "enabled", false),
             {:ok, timezone} <- utc_timezone(raw["timezone"]),
             {:ok, jitter} <- bounded_integer(raw, "jitterSec", 0, 0, 86_400),
             {:ok, timeout} <- bounded_integer(raw, "timeoutMs", 300_000, 1_000, 3_600_000),
             {:ok, retries} <- bounded_integer(raw, "maxRetries", 0, 0, 10),
             {:ok, backoff} <- bounded_integer(raw, "retryBackoffMs", 30_000, 1_000, 86_400_000),
             {:ok, monitor} <- optional_boolean(raw, "monitor", false),
             {:ok, notify_first} <- optional_boolean(raw, "monitorNotifyFirstRun", true) do
          projection = %{
            "id" => id,
            "kind" => "cron",
            "name" => name,
            "schedule" => schedule,
            "enabled" => enabled,
            "timezone" => timezone,
            "jitterSec" => jitter,
            "timeoutMs" => timeout,
            "maxRetries" => retries,
            "retryBackoffMs" => backoff,
            "monitor" => monitor,
            "monitorNotifyFirstRun" => notify_first,
            "promptBytes" => byte_size(prompt),
            "promptSha256" => sha256(prompt)
          }

          {:ok,
           %{
             id: id,
             name: name,
             prompt: prompt,
             schedule: schedule,
             enabled: enabled,
             timezone: timezone,
             jitter_sec: jitter,
             timeout_ms: timeout,
             max_retries: retries,
             retry_backoff_ms: backoff,
             monitor: monitor,
             monitor_notify_first_run: notify_first,
             projection: projection
           }}
        end
    end
  end

  defp plan_skills(bundle, profile) do
    skills_root = profile["paths"]["skills"]
    workspace = profile["paths"]["workspace"]

    bundle.skills
    |> Enum.reduce_while({:ok, []}, fn skill, {:ok, acc} ->
      destination = Path.join(skills_root, skill.key)
      disabled = Config.skill_disabled?(skill.key, workspace)

      action =
        case File.lstat(destination) do
          {:error, :enoent} ->
            if disabled, do: :create_enable, else: :create

          {:ok, %File.Stat{type: :directory}} ->
            case scan_skill_tree(destination) do
              {:ok, _} ->
                case Bundle.compute_hash(destination) do
                  {:ok, hash} when hash == skill.bundle_hash ->
                    if disabled, do: :enable, else: :unchanged

                  _ ->
                    :collision
                end

              _ ->
                :collision
            end

          _ ->
            :collision
        end

      current_digest =
        case action do
          :collision -> existing_skill_digest(destination)
          _ -> nil
        end

      {:cont,
       {:ok,
        [
          %{
            skill: skill,
            destination: destination,
            action: action,
            current_digest: current_digest
          }
          | acc
        ]}}
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _} = error -> error
    end
  end

  defp desired_job(bundle, profile) do
    automation = hd(bundle.automations)
    stable_id = stable_job_id(bundle.id, automation.id, profile["id"])

    {:ok,
     %{
       id: stable_id,
       name: automation.name,
       schedule: automation.schedule,
       enabled: automation.enabled,
       agent_id: profile["id"],
       session_key: profile["canonicalSessionKey"],
       prompt: automation.prompt,
       timezone: automation.timezone,
       jitter_sec: automation.jitter_sec,
       timeout_ms: automation.timeout_ms,
       max_retries: automation.max_retries,
       retry_backoff_ms: automation.retry_backoff_ms,
       monitor: automation.monitor,
       monitor_notify_first_run: automation.monitor_notify_first_run,
       meta: %{
         "blueprint" => %{
           "format" => @format,
           "version" => @version,
           "bundleId" => bundle.id,
           "automationId" => automation.id,
           "profileId" => profile["id"],
           "manifestDigest" => bundle.manifest_digest,
           "definitionDigest" => nil,
           "trustLevel" => "untrusted"
         }
       }
     }}
  end

  defp plan_automation(desired_job) do
    case CronStore.get_job(desired_job.id) do
      nil ->
        {:ok, %{action: :create, current_digest: nil}}

      %CronJob{} = existing ->
        if job_projection(existing) == desired_projection(desired_job) do
          {:ok, %{action: :unchanged, current_digest: digest(job_projection(existing))}}
        else
          {:ok, %{action: :collision, current_digest: digest(job_projection(existing))}}
        end
    end
  end

  defp definition_projection(bundle, profile, job) do
    %{
      "format" => @format,
      "version" => @version,
      "bundleId" => bundle.id,
      "manifestDigest" => bundle.manifest_digest,
      "profileId" => profile["id"],
      "canonicalSessionKey" => profile["canonicalSessionKey"],
      "skills" => Enum.map(bundle.skills, & &1.manifest_projection),
      "automation" => desired_projection(job, include_definition_digest: false)
    }
  end

  defp public_bundle(bundle, validated?) do
    %{
      "format" => @format,
      "version" => @version,
      "id" => bundle.id,
      "name" => bundle.name,
      "description" => bundle.description,
      "manifestDigest" => bundle.manifest_digest,
      "skills" => Enum.map(bundle.skills, & &1.manifest_projection),
      "automations" => Enum.map(bundle.automations, & &1.projection),
      "validation" => %{
        "valid" => validated?,
        "symlinksAllowed" => false,
        "archivesAllowed" => false,
        "commandJobsAllowed" => false,
        "secretValuesAllowed" => false,
        "trustLevel" => "untrusted",
        "auditStatus" => "pass"
      },
      "summary" => %{
        "skillCount" => length(bundle.skills),
        "automationCount" => length(bundle.automations),
        "promptTextReturned" => false,
        "skillTextReturned" => false,
        "pathsReturned" => false,
        "secretValuesReturned" => false
      }
    }
  end

  defp public_skill_action(action) do
    %{
      "key" => action.skill.key,
      "action" => Atom.to_string(action.action),
      "bundleHash" => action.skill.bundle_hash,
      "currentDigest" => action.current_digest,
      "sourceKind" => "portable_bundle",
      "trustLevel" => "untrusted",
      "auditStatus" => "pass",
      "fileCount" => action.skill.file_count,
      "bytes" => action.skill.bytes
    }
  end

  defp public_automation_action(action, desired_job) do
    %{
      "id" => desired_job.id,
      "action" => Atom.to_string(action.action),
      "kind" => "cron",
      "name" => desired_job.name,
      "schedule" => desired_job.schedule,
      "enabled" => desired_job.enabled,
      "timezone" => desired_job.timezone,
      "jitterSec" => desired_job.jitter_sec,
      "timeoutMs" => desired_job.timeout_ms,
      "maxRetries" => desired_job.max_retries,
      "retryBackoffMs" => desired_job.retry_backoff_ms,
      "monitor" => desired_job.monitor,
      "monitorNotifyFirstRun" => desired_job.monitor_notify_first_run,
      "promptBytes" => byte_size(desired_job.prompt),
      "promptSha256" => sha256(desired_job.prompt),
      "currentDigest" => action.current_digest,
      "target" => %{
        "agentId" => desired_job.agent_id,
        "sessionKey" => desired_job.session_key
      },
      "promptTextReturned" => false
    }
  end

  defp apply_skills(state, opts) do
    actions = Enum.filter(state.skill_actions, &(&1.action in [:create, :create_enable]))
    workspace = state.profile["paths"]["workspace"]
    config_path = Config.project_config_file(workspace)
    config_snapshot = snapshot_file(config_path)

    case stage_and_commit_skills(actions, state.profile["paths"]["skills"]) do
      {:ok, created} ->
        case enable_profile_skills(state.bundle.skills, workspace) do
          :ok ->
            case refresh_skills(workspace, opts) do
              :ok ->
                result =
                  Enum.map(state.skill_actions, fn action ->
                    status =
                      cond do
                        action.action in [:create, :create_enable] -> "created"
                        action.action == :enable -> "enabled"
                        true -> "unchanged"
                      end

                    %{
                      "key" => action.skill.key,
                      "status" => status,
                      "bundleHash" => action.skill.bundle_hash,
                      "trustLevel" => "untrusted",
                      "auditStatus" => "pass"
                    }
                  end)

                rollback = fn ->
                  rollback_skills(created)
                  restore_file(config_path, config_snapshot)
                  _ = refresh_skills(workspace, opts)
                  :ok
                end

                {:ok, result, rollback}

              {:error, _} = error ->
                rollback_skills(created)
                restore_file(config_path, config_snapshot)
                error
            end

          {:error, _} = error ->
            rollback_skills(created)
            restore_file(config_path, config_snapshot)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_automation(state, rollback) do
    case state.automation_action.action do
      :unchanged ->
        {:ok, %{"id" => state.desired_job.id, "status" => "unchanged", "kind" => "cron"}}

      :create ->
        case CronManager.add_new(state.desired_job) do
          {:ok, job} ->
            {:ok,
             %{
               "id" => job.id,
               "status" => "created",
               "kind" => "cron",
               "enabled" => job.enabled,
               "schedule" => job.schedule
             }}

          {:error, _reason} ->
            rollback.()
            error(:automation_create_failed, "Confirmed automation could not be created")
        end

      :collision ->
        rollback.()
        error(:conflict, "Automation ID collides with a different existing job")
    end
  end

  defp stage_and_commit_skills([], _skills_root), do: {:ok, []}

  defp stage_and_commit_skills(actions, skills_root) do
    stage =
      Path.join(skills_root, ".bundle-stage-#{System.unique_integer([:positive, :monotonic])}")

    with :ok <- File.mkdir_p(skills_root) |> map_write_error(:skill_write_failed),
         :ok <- ensure_absent(stage),
         :ok <- File.mkdir(stage) |> map_write_error(:skill_write_failed),
         :ok <- copy_staged_skills(actions, stage) do
      commit_staged_skills(actions, stage, [])
    else
      {:error, _} = error ->
        _ = File.rm_rf(stage)
        error
    end
  end

  defp copy_staged_skills(actions, stage) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      target = Path.join(stage, action.skill.key)

      case File.mkdir(target) do
        :ok ->
          case copy_skill_files(action.skill, target) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} ->
          {:halt, error(:skill_write_failed, "Profile skill staging failed")}
      end
    end)
  end

  defp copy_skill_files(skill, target) do
    Enum.reduce_while(skill.files, :ok, fn file, :ok ->
      destination = Path.join(target, file.path)

      with :ok <- File.mkdir_p(Path.dirname(destination)) |> map_write_error(:skill_write_failed),
           :ok <- File.cp(file.full_path, destination) |> map_write_error(:skill_write_failed),
           {:ok, %File.Stat{mode: mode}} <-
             File.stat(file.full_path) |> map_file_error(:skill_write_failed),
           :ok <-
             File.chmod(destination, Bitwise.band(mode, 0o777))
             |> map_write_error(:skill_write_failed) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp commit_staged_skills([], stage, created) do
    _ = File.rmdir(stage)
    {:ok, Enum.reverse(created)}
  end

  defp commit_staged_skills([action | rest], stage, created) do
    staged = Path.join(stage, action.skill.key)

    case ensure_absent(action.destination) do
      :ok ->
        case File.rename(staged, action.destination) do
          :ok -> commit_staged_skills(rest, stage, [action | created])
          {:error, _} -> rollback_committed(created, stage)
        end

      {:error, _} ->
        rollback_committed(created, stage)
    end
  end

  defp rollback_committed(created, stage) do
    rollback_skills(created)
    _ = File.rm_rf(stage)
    error(:skill_collision, "Profile skill state changed during activation")
  end

  defp rollback_skills(created) do
    Enum.each(created, fn action ->
      case Bundle.compute_hash(action.destination) do
        {:ok, hash} when hash == action.skill.bundle_hash -> File.rm_rf(action.destination)
        _ -> :ok
      end
    end)
  end

  defp enable_profile_skills(skills, workspace) do
    Enum.reduce_while(skills, :ok, fn skill, :ok ->
      case LemonSkills.enable(skill.key, cwd: workspace, global: false) do
        :ok ->
          {:cont, :ok}

        {:error, _} ->
          {:halt, error(:skill_enable_failed, "Profile-local skill enablement failed")}
      end
    end)
  end

  defp refresh_skills(workspace, opts) do
    refresher = Keyword.get(opts, :refresh_fun, &LemonSkills.refresh/1)

    case refresher.(cwd: workspace) do
      :ok -> :ok
      _ -> error(:skill_refresh_failed, "Skill registry refresh failed")
    end
  rescue
    _ -> error(:skill_refresh_failed, "Skill registry refresh failed")
  catch
    :exit, _ -> error(:skill_refresh_failed, "Skill registry refresh failed")
  end

  defp require_activatable(%{"canActivate" => true}), do: :ok
  defp require_activatable(_), do: error(:conflict, "Preview contains destination collisions")

  defp verify_confirmation(%{"confirmationDigest" => expected}, supplied) do
    if byte_size(expected) == byte_size(supplied) and :crypto.hash_equals(expected, supplied) do
      :ok
    else
      error(:confirmation_mismatch, "Confirmation digest is missing, stale, or incorrect")
    end
  end

  defp activation_summary(skills, automation) do
    status_counts = skills |> Enum.map(& &1["status"]) |> Enum.frequencies()

    %{
      "skillStatusCounts" => status_counts,
      "createdAutomationCount" => if(automation["status"] == "created", do: 1, else: 0),
      "unchangedAutomationCount" => if(automation["status"] == "unchanged", do: 1, else: 0),
      "duplicateSafe" => true,
      "promptTextReturned" => false,
      "skillTextReturned" => false,
      "secretValuesReturned" => false,
      "pathsReturned" => false
    }
  end

  defp scan_skill_tree(root) do
    with {:ok, root} <- require_directory(root, :invalid_skill_path),
         {:ok, names} <- File.ls(root) |> map_file_error(:invalid_skill_path),
         true <- "SKILL.md" in names || error(:invalid_skill, "Skill is missing SKILL.md"),
         true <-
           not Enum.any?(names, &archive_extension?/1) ||
             error(:archive_not_supported, "Skill bundles cannot contain archives"),
         true <-
           Enum.all?(names, &(&1 in @allowed_skill_root_entries)) ||
             error(
               :invalid_skill_layout,
               "Skill contains files outside the audited bundle layout"
             ) do
      walk_skill_entries(root, root, names, %{files: 0, bytes: 0, file_entries: []})
    else
      {:error, _} = error -> error
    end
  end

  defp walk_skill_entries(_root, _current, [], state), do: {:ok, state}

  defp walk_skill_entries(root, current, [name | rest], state) do
    path = Path.join(current, name)
    relative = Path.relative_to(path, root) |> String.replace("\\", "/")

    cond do
      byte_size(relative) > 512 ->
        error(:bundle_limit_exceeded, "Skill path exceeds the byte limit")

      archive_extension?(path) ->
        error(:archive_not_supported, "Skill bundles cannot contain archives")

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :symlink}} ->
            error(:symlink_not_allowed, "Skill bundles cannot contain symlinks")

          {:ok, %File.Stat{type: :directory}} ->
            with {:ok, children} <- File.ls(path) |> map_file_error(:invalid_skill_path),
                 {:ok, next} <- walk_skill_entries(root, path, Enum.sort(children), state) do
              walk_skill_entries(root, current, rest, next)
            end

          {:ok, %File.Stat{type: :regular, size: size}} ->
            cond do
              size > @max_file_bytes ->
                error(:bundle_limit_exceeded, "Skill file exceeds the byte limit")

              state.files + 1 > @max_files ->
                error(:bundle_limit_exceeded, "Bundle contains too many files")

              state.bytes + size > @max_total_bytes ->
                error(:bundle_limit_exceeded, "Bundle exceeds the total byte limit")

              true ->
                entry = %{path: relative, full_path: path, size: size}

                next = %{
                  files: state.files + 1,
                  bytes: state.bytes + size,
                  file_entries: [entry | state.file_entries]
                }

                walk_skill_entries(root, current, rest, next)
            end

          {:ok, _} ->
            error(
              :unsafe_file_type,
              "Skill bundles may contain regular files and directories only"
            )

          {:error, _} ->
            error(:invalid_skill_path, "Skill bundle entry could not be inspected")
        end
    end
  end

  defp existing_skill_digest(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type, size: size}} ->
        digest(%{"type" => to_string(type), "size" => size})

      _ ->
        digest(%{"state" => "unreadable"})
    end
  end

  defp job_projection(%CronJob{} = job) do
    %{
      "id" => job.id,
      "name" => job.name,
      "schedule" => job.schedule,
      "enabled" => job.enabled,
      "agentId" => job.agent_id,
      "sessionKey" => job.session_key,
      "promptBytes" => if(is_binary(job.prompt), do: byte_size(job.prompt), else: 0),
      "promptSha256" => if(is_binary(job.prompt), do: sha256(job.prompt), else: nil),
      "commandPresent" => is_binary(job.command) and String.trim(job.command) != "",
      "timezone" => job.timezone,
      "jitterSec" => job.jitter_sec,
      "timeoutMs" => job.timeout_ms,
      "maxRetries" => job.max_retries,
      "retryBackoffMs" => job.retry_backoff_ms,
      "monitor" => job.monitor,
      "monitorNotifyFirstRun" => job.monitor_notify_first_run,
      "blueprint" => normalize_blueprint_meta(job.meta)
    }
  end

  defp desired_projection(job, opts \\ []) do
    blueprint = get_in(job, [:meta, "blueprint"])

    blueprint =
      if Keyword.get(opts, :include_definition_digest, true) do
        blueprint
      else
        Map.delete(blueprint, "definitionDigest")
      end

    %{
      "id" => job.id,
      "name" => job.name,
      "schedule" => job.schedule,
      "enabled" => job.enabled,
      "agentId" => job.agent_id,
      "sessionKey" => job.session_key,
      "promptBytes" => byte_size(job.prompt),
      "promptSha256" => sha256(job.prompt),
      "commandPresent" => false,
      "timezone" => job.timezone,
      "jitterSec" => job.jitter_sec,
      "timeoutMs" => job.timeout_ms,
      "maxRetries" => job.max_retries,
      "retryBackoffMs" => job.retry_backoff_ms,
      "monitor" => job.monitor,
      "monitorNotifyFirstRun" => job.monitor_notify_first_run,
      "blueprint" => blueprint
    }
  end

  defp normalize_blueprint_meta(meta) when is_map(meta) do
    value = Map.get(meta, "blueprint") || Map.get(meta, :blueprint)

    if is_map(value) do
      Map.new(value, fn {key, val} -> {to_string(key), val} end)
    else
      nil
    end
  end

  defp normalize_blueprint_meta(_), do: nil

  defp stable_job_id(bundle_id, automation_id, profile_id) do
    suffix = sha256(Enum.join([bundle_id, automation_id, profile_id], "\n")) |> binary_part(0, 32)
    "cron_blueprint_" <> suffix
  end

  defp normalize_schedule(schedule) when is_binary(schedule) do
    with {:ok, normalized} <- CronSchedule.normalize(schedule),
         {:ok, _} <- CronSchedule.parse(normalized) do
      {:ok, normalized}
    else
      _ -> error(:invalid_schedule, "Automation schedule is invalid")
    end
  end

  defp normalize_schedule(_), do: error(:invalid_schedule, "Automation schedule is required")

  defp utc_timezone(nil), do: {:ok, "UTC"}
  defp utc_timezone("UTC"), do: {:ok, "UTC"}
  defp utc_timezone(_), do: error(:invalid_timezone, "Bundle version 1 requires UTC timezone")

  defp optional_boolean(map, key, default) do
    case Map.fetch(map, key) do
      :error -> {:ok, default}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> error(:invalid_automation, "Automation boolean field is invalid")
    end
  end

  defp bounded_integer(map, key, default, min, max) do
    value = Map.get(map, key, default)

    if is_integer(value) and value >= min and value <= max do
      {:ok, value}
    else
      error(:invalid_automation, "Automation numeric field is outside its allowed range")
    end
  end

  defp validate_id(value, _field) when is_binary(value) do
    if Regex.match?(@id_regex, value),
      do: {:ok, value},
      else: error(:invalid_id, "Bundle and entry IDs must use lowercase safe identifiers")
  end

  defp validate_id(_, _), do: error(:invalid_id, "Bundle and entry IDs are required")

  defp safe_text(value, _field, max, multiline?) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        error(:invalid_text, "Required bundle text is empty")

      not String.valid?(trimmed) ->
        error(:invalid_text, "Bundle text must be valid UTF-8")

      byte_size(trimmed) > max ->
        error(:invalid_text, "Bundle text exceeds its byte limit")

      Regex.match?(@control_regex, trimmed) ->
        error(:invalid_text, "Bundle text contains control characters")

      Regex.match?(@bidi_regex, trimmed) ->
        error(:invalid_text, "Bundle text contains bidirectional control characters")

      not multiline? and (String.contains?(trimmed, "\n") or String.contains?(trimmed, "\r")) ->
        error(:invalid_text, "Bundle label text must be single-line")

      true ->
        {:ok, trimmed}
    end
  end

  defp safe_text(_, _, _, _), do: error(:invalid_text, "Required bundle text is invalid")

  defp optional_safe_text(nil, _field, _max), do: {:ok, nil}
  defp optional_safe_text("", _field, _max), do: {:ok, nil}
  defp optional_safe_text(value, field, max), do: safe_text(value, field, max, false)

  defp reject_secret_manifest_values(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, child}, :ok ->
      cond do
        Regex.match?(@secret_key_regex, to_string(key)) ->
          {:halt,
           error(
             :secret_value_not_allowed,
             "Bundle manifests cannot contain secret-bearing fields"
           )}

        true ->
          case reject_secret_manifest_values(child) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp reject_secret_manifest_values(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn child, :ok ->
      case reject_secret_manifest_values(child) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reject_secret_manifest_values(value) when is_binary(value), do: reject_secret_value(value)
  defp reject_secret_manifest_values(_), do: :ok

  defp reject_secret_value(value) do
    if Enum.any?(@secret_value_regexes, &Regex.match?(&1, value)) do
      error(:secret_value_not_allowed, "Bundle manifests cannot contain credential-like values")
    else
      :ok
    end
  end

  defp require_directory(path, code) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        error(:symlink_not_allowed, "Bundle paths cannot be symlinks")

      _ ->
        error(code, "Required bundle directory is unavailable")
    end
  end

  defp require_regular_file(path, code) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        error(:symlink_not_allowed, "Bundle files cannot be symlinks")

      _ ->
        error(code, "Required bundle manifest is unavailable")
    end
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> error(:skill_collision, "Profile skill destination already exists")
    end
  end

  defp archive_extension?(path), do: String.downcase(Path.extname(path)) in @archive_extensions

  defp profile_get(profile_id, opts) do
    case ProfileStore.get(profile_id, Keyword.get(opts, :profile_opts, [])) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> error(:profile_not_found, "Profile does not exist")
      _ -> error(:invalid_profile, "Profile is invalid or unavailable")
    end
  end

  defp snapshot_file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:present, bytes}
      {:error, :enoent} -> :missing
      {:error, _} -> :unavailable
    end
  end

  defp restore_file(path, {:present, bytes}) do
    _ = File.mkdir_p(Path.dirname(path))
    File.write(path, bytes)
  end

  defp restore_file(path, :missing), do: File.rm(path)
  defp restore_file(_path, :unavailable), do: :ok

  defp map_bundle_error({:ok, _} = ok), do: ok
  defp map_bundle_error(_), do: error(:invalid_skill, "Skill bundle could not be hashed")

  defp map_manifest_error({:ok, _, _} = ok), do: ok
  defp map_manifest_error(_), do: error(:invalid_skill, "Skill manifest is invalid")

  defp map_file_error({:ok, value}, _code), do: {:ok, value}
  defp map_file_error({:error, _}, code), do: error(code, "Bundle file operation failed")

  defp map_write_error(:ok, _code), do: :ok
  defp map_write_error({:error, _}, code), do: error(code, "Profile skill write failed")

  defp digest(value), do: value |> canonical_json() |> sha256()

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {to_string(key), child} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, child} ->
      Jason.encode!(key) <> ":" <> canonical_json(child)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp error(code, message), do: {:error, {code, message}}
end
