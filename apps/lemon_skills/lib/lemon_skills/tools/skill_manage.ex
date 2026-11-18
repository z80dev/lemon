defmodule LemonSkills.Tools.SkillManage do
  @moduledoc """
  Agent-facing skill authoring and maintenance tool.

  This is Lemon's procedural-memory write path: agents can turn learned
  workflows into local skills, then maintain those skills with small edits and
  supporting files. Writes are scoped to Lemon skill directories and audited
  before they are exposed through the registry.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonSkills.Audit.{BundleAudit, State}
  alias LemonSkills.{Bundle, Config, Installer, Manifest, Registry, SkillRoot}

  @max_name_length 64
  @max_skill_content_chars 100_000
  @max_supporting_file_bytes 1_048_576
  @allowed_support_dirs ~w(assets references scripts templates)
  @name_re ~r/^[a-z0-9][a-z0-9._-]*$/

  @doc """
  Return the `skill_manage` tool definition.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    cwd = Keyword.get(opts, :cwd)

    telemetry_context =
      Map.put(
        telemetry_context(opts),
        :write_approval_context,
        LemonSkills.WriteApproval.context(opts)
      )

    %AgentTool{
      name: "skill_manage",
      label: "Manage Skill",
      description: """
      Create, edit, patch, delete, and maintain Lemon skills as procedural memory. \
      Use this when you learn a reusable workflow that should become a skill, \
      or when an existing user/project skill needs refinement. Use scope="project" \
      for repository-specific skills and scope="global" for reusable cross-project skills.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "create",
              "edit",
              "patch",
              "delete",
              "write_file",
              "remove_file",
              "pin",
              "unpin",
              "archive",
              "restore",
              "report"
            ],
            "description" => "Skill operation to perform."
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Skill key/directory name. Use lowercase letters, numbers, hyphens, dots, or underscores."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["project", "global"],
            "description" => "Where to write the skill. Defaults to project."
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "Full SKILL.md content for create/edit, including YAML/TOML frontmatter."
          },
          "file_path" => %{
            "type" => "string",
            "description" =>
              "Optional target file. Omit for SKILL.md on patch; supporting files must be under references/, templates/, scripts/, or assets/."
          },
          "file_content" => %{
            "type" => "string",
            "description" => "Content for write_file."
          },
          "old_string" => %{
            "type" => "string",
            "description" => "Text to replace for patch. Must match exactly."
          },
          "new_string" => %{
            "type" => "string",
            "description" => "Replacement text for patch. Use an empty string to delete."
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences for patch. Defaults to false."
          },
          "stale_after_days" => %{
            "type" => "integer",
            "description" =>
              "For report: mark active agent-authored skills stale after this many idle days. Defaults to 30."
          },
          "archive_after_days" => %{
            "type" => "integer",
            "description" =>
              "For report: mark active agent-authored skills archive candidates after this many idle days. Defaults to 90."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, telemetry_context)
    }
  end

  @doc """
  Tool callback entry: `execute(tool_call_id, params, signal, on_update, cwd)`.

  Delegates to `execute/6` with an empty telemetry context (`%{}`).
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, _on_update, cwd) do
    execute(tool_call_id, params, signal, nil, cwd, %{})
  end

  @doc """
  Full tool callback form invoked by the agent loop, wired by `tool/1`:
  `execute(tool_call_id, params, signal, on_update, cwd, telemetry_context)`.

  Reads from `params`:

  - `"action"` (required) - `"create"`, `"edit"`, `"patch"`, `"delete"`,
    `"write_file"`, `"remove_file"`, `"pin"`, `"unpin"`, `"archive"`, `"restore"`,
    or `"report"`
  - `"scope"` (default `"project"`) - `"project"` or `"global"`
  - `"name"` (required for all actions except `"report"`) - skill key/directory
    name matching `^[a-z0-9][a-z0-9._-]*$`, at most 64 characters
  - `"content"` (create/edit) - full `SKILL.md` content including frontmatter, at
    most 100_000 characters and validated as a manifest with a body
  - `"old_string"` (patch) - exact text to replace; must match at least once
  - `"new_string"` (patch) - replacement text (empty string deletes)
  - `"replace_all"` (patch, default `false`) - replace every occurrence; required
    when `old_string` matches more than once
  - `"file_path"` (patch/write_file/remove_file) - target file; omitted means
    `SKILL.md`; supporting files must sit under `references/`, `templates/`,
    `scripts/`, or `assets/`
  - `"file_content"` (write_file) - supporting file content, at most 1 MiB and
    100_000 characters
  - `"stale_after_days"` (report, default `30`) / `"archive_after_days"` (report,
    default `90`) - positive integers (or integer strings)

  Content changes (create, edit, patch, write_file, remove_file) are built in a
  private staging copy outside every skill root, audited there via
  `LemonSkills.Audit.BundleAudit`, and only the audited file set is activated;
  a blocked bundle is never published. The registry is refreshed afterwards. Returns
  `%LemonAgent.Types.AgentToolResult{}` on success with `content` holding a
  status message and `details` an action-specific map (`path`, `file_path`,
  `replacements`, `audit`, `lifecycle_state`, `skills`, ...). Errors surface as
  `{:error, String.t()}` tuples; an aborted signal returns
  `{:error, "Operation aborted"}`. Emits `LemonSkills.Telemetry.skill_write/1`
  for every result.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil,
          map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, _on_update, cwd, telemetry_context) do
    result =
      if AbortSignal.aborted?(signal) do
        {:error, "Operation aborted"}
      else
        with {:ok, action} <- required_string(params, "action"),
             {:ok, scope} <- parse_scope(Map.get(params, "scope", "project")),
             {:ok, root} <- skills_root(scope, cwd),
             {:ok, name} <- name_for_action(action, params),
             :ok <- validate_name_for_action(action, name) do
          with :ok <- reject_pinned_content_edit(action, name, scope, cwd),
               :ok <-
                 approve_mutation(action, scope, params, cwd, telemetry_context, tool_call_id) do
            dispatch(action, name, params, scope, root, cwd)
          end
        end
      end

    emit_skill_write(result, params, tool_call_id, cwd, telemetry_context)
    result
  end

  defp approve_mutation("report", _scope, _params, _cwd, _context, _id), do: :ok

  # Global skills live in the agent directory, which is Lemon operator state:
  # a global mutation always needs a human approval, whatever
  # `[skills] write_approval` says, and is refused without an interactive
  # approver (cron, automation, background runs).
  defp approve_mutation(_action, scope, params, cwd, context, id) do
    context = Map.get(context, :write_approval_context, context)

    LemonSkills.WriteApproval.check(
      :skills,
      "skill_manage",
      params,
      Map.put(context, :cwd, cwd),
      id,
      force: scope == :global
    )
  end

  defp dispatch("create", name, params, scope, root, cwd) do
    with {:ok, content} <- required_string(params, "content", preserve?: true),
         :ok <- validate_skill_content(content),
         {:ok, dir} <- new_skill_dir(root, name),
         :ok <- SkillRoot.ensure_dir(root_anchor(scope, cwd), root),
         {:ok, audit, _} <-
           stage_audit_activate(scope, cwd, name, nil, dir, fn proposed ->
             File.write(Path.join(proposed, "SKILL.md"), content)
           end),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' created at #{dir}.", %{action: "create", path: dir, audit: audit})
    end
  end

  defp dispatch("edit", name, params, scope, root, cwd) do
    with {:ok, content} <- required_string(params, "content", preserve?: true),
         :ok <- validate_skill_content(content),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, audit, _} <-
           stage_audit_activate(scope, cwd, name, dir, dir, fn proposed ->
             File.write(Path.join(proposed, "SKILL.md"), content)
           end),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' updated.", %{action: "edit", path: dir, audit: audit})
    end
  end

  defp dispatch("patch", name, params, scope, root, cwd) do
    replace_all? = truthy?(Map.get(params, "replace_all"))

    with {:ok, old_string} <- required_string(params, "old_string", preserve?: true),
         {:ok, new_string} <-
           required_string(params, "new_string", allow_empty?: true, preserve?: true),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, rel} <- target_rel(Map.get(params, "file_path")),
         {:ok, audit, replacements} <-
           stage_audit_activate(scope, cwd, name, dir, dir, fn proposed ->
             with {:ok, original} <- read_staged_file(proposed, rel),
                  {:ok, updated, count} <-
                    patch_content(original, old_string, new_string, replace_all?),
                  :ok <- validate_target_content(rel, updated),
                  :ok <- File.write(Path.join(proposed, rel), updated) do
               {:ok, count}
             end
           end),
         :ok <- refresh_registry(scope, cwd) do
      ok("Patched #{rel} in skill '#{name}' (#{replacements} replacement(s)).", %{
        action: "patch",
        path: dir,
        file_path: rel,
        replacements: replacements,
        audit: audit
      })
    end
  end

  defp dispatch("delete", name, _params, scope, root, cwd) do
    with {:ok, dir} <- existing_skill_dir(root, name),
         :ok <- reject_pinned(name, scope, cwd, "delete"),
         :ok <- SkillRoot.remove(root_anchor(scope, cwd), dir),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' deleted.", %{action: "delete", path: dir})
    end
  end

  defp dispatch("write_file", name, params, scope, root, cwd) do
    with {:ok, file_path} <- required_string(params, "file_path"),
         {:ok, file_content} <-
           required_string(params, "file_content", allow_empty?: true, preserve?: true),
         :ok <- validate_supporting_file_size(file_content),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, rel} <- target_rel(file_path),
         {:ok, audit, _} <-
           stage_audit_activate(scope, cwd, name, dir, dir, fn proposed ->
             target = Path.join(proposed, rel)

             with :ok <- File.mkdir_p(Path.dirname(target)) do
               File.write(target, file_content)
             end
           end),
         :ok <- refresh_registry(scope, cwd) do
      ok("File '#{rel}' written to skill '#{name}'.", %{
        action: "write_file",
        path: dir,
        file_path: rel,
        audit: audit
      })
    end
  end

  defp dispatch("remove_file", name, params, scope, root, cwd) do
    with {:ok, file_path} <- required_string(params, "file_path"),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, rel} <- target_rel(file_path),
         {:ok, audit, _} <-
           stage_audit_activate(scope, cwd, name, dir, dir, fn proposed ->
             target = Path.join(proposed, rel)

             case File.lstat(target) do
               {:ok, %File.Stat{type: :regular}} -> File.rm(target)
               _ -> {:error, "File not found: #{rel}"}
             end
           end),
         :ok <- refresh_registry(scope, cwd) do
      ok("File '#{rel}' removed from skill '#{name}'.", %{
        action: "remove_file",
        path: dir,
        file_path: rel,
        audit: audit
      })
    end
  end

  defp dispatch("pin", name, _params, scope, root, cwd) do
    with {:ok, dir} <- existing_skill_dir(root, name),
         :ok <- LemonSkills.Usage.set_state(name, :pinned, usage_opts(scope, cwd)) do
      ok("Skill '#{name}' pinned.", %{
        action: "pin",
        path: dir,
        lifecycle_state: "pinned"
      })
    end
  end

  defp dispatch("unpin", name, _params, scope, root, cwd) do
    with {:ok, dir} <- existing_skill_dir(root, name),
         :ok <- LemonSkills.Usage.set_state(name, :active, usage_opts(scope, cwd)) do
      ok("Skill '#{name}' unpinned.", %{
        action: "unpin",
        path: dir,
        lifecycle_state: "active"
      })
    end
  end

  defp dispatch("archive", name, _params, scope, root, cwd) do
    with {:ok, dir} <- existing_skill_dir(root, name),
         :ok <- reject_pinned(name, scope, cwd, "archive"),
         :ok <- LemonSkills.Usage.set_state(name, :archived, usage_opts(scope, cwd)),
         :ok <- LemonSkills.Config.disable(name, global: scope == :global, cwd: cwd),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' archived.", %{
        action: "archive",
        path: dir,
        lifecycle_state: "archived"
      })
    end
  end

  defp dispatch("restore", name, _params, scope, root, cwd) do
    with {:ok, dir} <- existing_skill_dir(root, name),
         :ok <- LemonSkills.Usage.set_state(name, :active, usage_opts(scope, cwd)),
         :ok <- LemonSkills.Config.enable(name, global: scope == :global, cwd: cwd),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' restored.", %{
        action: "restore",
        path: dir,
        lifecycle_state: "active"
      })
    end
  end

  defp dispatch("report", _name, params, scope, _root, cwd) do
    opts =
      usage_opts(scope, cwd) ++
        [
          stale_after_days: positive_integer_param(params, "stale_after_days", 30),
          archive_after_days: positive_integer_param(params, "archive_after_days", 90)
        ]

    rows = LemonSkills.Usage.report(opts)

    ok(format_report(rows, scope), %{
      action: "report",
      scope: Atom.to_string(scope),
      skills: rows
    })
  end

  defp dispatch(action, _name, _params, _scope, _root, _cwd) do
    {:error,
     "Unknown action '#{action}'. Use create, edit, patch, delete, write_file, remove_file, pin, unpin, archive, restore, or report."}
  end

  defp required_string(params, key, opts \\ []) do
    allow_empty? = Keyword.get(opts, :allow_empty?, false)
    preserve? = Keyword.get(opts, :preserve?, false)

    case Map.get(params, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" and not allow_empty? do
          {:error, "#{key} must be a non-empty string"}
        else
          {:ok, if(preserve?, do: value, else: trimmed)}
        end

      _ ->
        {:error, "missing required string parameter: #{key}"}
    end
  end

  defp parse_scope("global"), do: {:ok, :global}
  defp parse_scope("project"), do: {:ok, :project}
  defp parse_scope(_), do: {:error, "scope must be 'project' or 'global'"}

  defp name_for_action("report", params), do: {:ok, Map.get(params, "name", "")}
  defp name_for_action(_action, params), do: required_string(params, "name")

  defp validate_name_for_action("report", ""), do: :ok
  defp validate_name_for_action(_action, name), do: validate_name(name)

  # The scope's mutable root, resolved against its trusted anchor: the
  # project's `LemonCore.TrustedRoot`, or the validated agent dir for the
  # global root. Every component below the anchor must be a real directory.
  defp skills_root(scope, cwd) do
    with {:ok, configured} <- configured_root(scope, cwd),
         {:ok, root, anchor} <- SkillRoot.resolve_root(configured, audit_scope(scope, cwd)),
         :ok <- SkillRoot.check_dir(anchor, root, allow_missing: true) do
      {:ok, root}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Unsafe #{scope} skill directory: #{inspect(reason)}"}
    end
  end

  defp configured_root(:global, _cwd), do: {:ok, Config.global_skills_dir()}

  defp configured_root(:project, cwd) when is_binary(cwd) and cwd != "",
    do: {:ok, Config.project_skills_dir(cwd)}

  defp configured_root(:project, _cwd), do: {:error, "project scope requires cwd"}

  defp root_anchor(:global, _cwd), do: Path.expand(Config.agent_dir())
  defp root_anchor(:project, cwd), do: LemonCore.TrustedRoot.skill_root(cwd)

  defp validate_name(name) do
    cond do
      String.length(name) > @max_name_length ->
        {:error, "name exceeds #{@max_name_length} characters"}

      not Regex.match?(@name_re, name) ->
        {:error, "invalid skill name '#{name}'"}

      true ->
        :ok
    end
  end

  defp validate_skill_content(content) do
    cond do
      String.length(content) > @max_skill_content_chars ->
        {:error, "SKILL.md content exceeds #{@max_skill_content_chars} characters"}

      true ->
        with {:ok, manifest, body} <- Manifest.parse_and_validate(content),
             :ok <- require_manifest_string(manifest, "name"),
             :ok <- require_manifest_string(manifest, "description"),
             :ok <- require_body(body) do
          :ok
        end
    end
  end

  defp require_manifest_string(manifest, key) do
    case Map.get(manifest, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "#{key} must be non-empty"}, else: :ok

      _ ->
        {:error, "frontmatter must include #{key}"}
    end
  end

  defp require_body(body) do
    if String.trim(body) == "" do
      {:error, "SKILL.md must include instructions after frontmatter"}
    else
      :ok
    end
  end

  defp validate_supporting_file_size(content) do
    bytes = byte_size(content)

    cond do
      bytes > @max_supporting_file_bytes ->
        {:error, "supporting file exceeds #{@max_supporting_file_bytes} bytes"}

      String.length(content) > @max_skill_content_chars ->
        {:error, "supporting file exceeds #{@max_skill_content_chars} characters"}

      true ->
        :ok
    end
  end

  defp new_skill_dir(root, name) do
    dir = Path.join(root, name)

    if File.exists?(dir) do
      {:error, "Skill '#{name}' already exists at #{dir}"}
    else
      {:ok, dir}
    end
  end

  defp existing_skill_dir(root, name) do
    dir = Path.join(root, name)
    skill_file = Path.join(dir, "SKILL.md")

    cond do
      not safe_directory?(dir) ->
        {:error, "Skill '#{name}' not found at #{dir}"}

      not File.regular?(skill_file) ->
        {:error, "Skill '#{name}' is missing SKILL.md"}

      true ->
        {:ok, dir}
    end
  end

  defp target_rel(nil), do: {:ok, "SKILL.md"}
  defp target_rel(""), do: {:ok, "SKILL.md"}

  defp target_rel(file_path) when is_binary(file_path) do
    parts = Path.split(file_path)
    segments = String.split(file_path, "/")

    cond do
      Path.type(file_path) == :absolute or ".." in parts ->
        {:error, "file_path must be relative and may not contain '..'"}

      String.contains?(file_path, "\\") or
          Enum.any?(segments, &(&1 in ["", "."] or String.starts_with?(&1, "."))) ->
        {:error, "file_path segments may not be empty or hidden (start with '.')"}

      parts == [] or hd(parts) not in @allowed_support_dirs ->
        {:error, "file_path must be under one of: #{Enum.join(@allowed_support_dirs, ", ")}"}

      length(parts) < 2 ->
        {:error, "file_path must include a filename under #{hd(parts)}/"}

      true ->
        {:ok, Enum.join(segments, "/")}
    end
  end

  defp target_rel(_), do: {:error, "file_path must be a string"}

  defp validate_target_content("SKILL.md", content), do: validate_skill_content(content)
  defp validate_target_content(_rel, content), do: validate_supporting_file_size(content)

  defp patch_content(content, old_string, new_string, replace_all?) do
    matches = :binary.matches(content, old_string)
    count = length(matches)

    cond do
      count == 0 ->
        {:error, "old_string was not found"}

      count > 1 and not replace_all? ->
        {:error, "old_string matched #{count} times; pass replace_all=true to replace all"}

      true ->
        {:ok, String.replace(content, old_string, new_string, global: replace_all?), count}
    end
  end

  defp audit_scope(:global, _cwd), do: :global
  defp audit_scope(:project, cwd), do: {:project, cwd}

  defp usage_opts(:global, _cwd), do: [scope: :global]
  defp usage_opts(:project, cwd), do: [scope: :project, cwd: cwd]

  defp positive_integer_param(params, key, default) do
    case Map.get(params, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp format_report([], scope), do: "No #{scope} skill usage records found."

  defp format_report(rows, scope) do
    header = "Skill usage report for #{scope} scope:"

    body =
      rows
      |> Enum.map(fn row ->
        markers =
          [
            if(row.archive_candidate, do: "archive-candidate"),
            if(row.stale_candidate, do: "stale-candidate"),
            row.lifecycle_state
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.join(", ")

        last_activity = row.last_activity_at || "never"
        idle_days = row.idle_days || "unknown"

        "- #{row.name}: #{markers}; loads=#{row.load_count}; writes=#{row.write_count}; idle_days=#{idle_days}; last_activity=#{last_activity}"
      end)
      |> Enum.join("\n")

    header <> "\n" <> body
  end

  defp reject_pinned_content_edit(action, name, scope, cwd)
       when action in ["edit", "patch", "write_file", "remove_file"],
       do: reject_pinned(name, scope, cwd, "editing its contents")

  defp reject_pinned_content_edit(_action, _name, _scope, _cwd), do: :ok

  defp reject_pinned(name, scope, cwd, action) do
    if LemonSkills.Usage.pinned?(name, usage_opts(scope, cwd)) do
      {:error, "Skill '#{name}' is pinned; unpin it before #{action}."}
    else
      :ok
    end
  end

  defp summarize_audit(audit) do
    %{
      status: Atom.to_string(BundleAudit.audit_status(audit)),
      findings: BundleAudit.audit_findings(audit),
      approval_required: audit["approval_required"] || false
    }
  end

  defp format_findings(audit) do
    case BundleAudit.audit_findings(audit) do
      [] -> "blocked"
      findings -> Enum.take(findings, 3) |> Enum.join("; ")
    end
  end

  # Builds the proposed bundle in a private staging dir outside every skill
  # root: a copy of the live bundle's verified files (a live bundle holding a
  # symlink, hard link or any other layout violation is refused before any
  # file is read), then `mutate` applied to that copy. The staged bundle is
  # scanned and audited, and only that exact audited file set is activated
  # through `Installer.activate_audited/4`. Nothing is published before the
  # audit passes, so there is never a rollback of live content.
  defp stage_audit_activate(scope, cwd, name, live_dir, dest, mutate) do
    Installer.with_private_staging(fn staging ->
      proposed = Path.join(staging, "bundle")

      with :ok <- seed_proposed(live_dir, proposed),
           {:ok, meta} <- run_mutation(mutate, proposed),
           {:ok, scan} <- scan_proposed(proposed),
           {:ok, audit} <- audit_proposed(proposed, scan, audit_scope(scope, cwd), name),
           :ok <- activate_proposed(scan, dest, scope, cwd, live_dir != nil),
           :ok <- grant_passed(audit, scope, cwd, name) do
        {:ok, summarize_audit(audit), meta}
      end
    end)
  end

  defp seed_proposed(nil, proposed), do: File.mkdir(proposed)

  defp seed_proposed(live_dir, proposed) do
    case Bundle.scan(live_dir) do
      {:ok, %{violations: []} = scan} ->
        case Bundle.copy_files(scan, proposed) do
          :ok -> :ok
          {:error, reason} -> {:error, "Skill changed while staging: #{inspect(reason)}"}
        end

      {:ok, %{violations: violations}} ->
        {:error,
         "Skill has unsafe entries and cannot be edited: " <>
           Enum.map_join(Enum.take(violations, 3), "; ", &Bundle.describe_violation/1)}

      {:error, reason} ->
        {:error, "Cannot read skill bundle: #{inspect(reason)}"}
    end
  end

  defp run_mutation(mutate, proposed) do
    case mutate.(proposed) do
      :ok -> {:ok, nil}
      {:ok, meta} -> {:ok, meta}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Failed to stage skill change: #{inspect(reason)}"}
    end
  end

  defp scan_proposed(proposed) do
    case Bundle.scan(proposed) do
      {:ok, %{violations: []} = scan} ->
        {:ok, scan}

      {:ok, %{violations: violations}} ->
        {:error,
         "Skill blocked by security audit: " <>
           Enum.map_join(Enum.take(violations, 3), "; ", &Bundle.describe_violation/1)}

      {:error, reason} ->
        {:error, "Cannot scan staged skill: #{inspect(reason)}"}
    end
  end

  defp audit_proposed(proposed, scan, audit_scope, name) do
    hash = Bundle.hash(scan)

    case BundleAudit.audit(proposed, audit_scope, name, kind: :skill, force: true) do
      {:ok, %{"bundle_hash" => ^hash} = audit} ->
        case BundleAudit.audit_status(audit) do
          :block -> {:error, "Skill blocked by security audit: #{format_findings(audit)}"}
          _ -> {:ok, audit}
        end

      {:ok, _audit} ->
        {:error, "Staged skill changed during audit"}

      {:error, reason} ->
        {:error, "Skill audit failed: #{inspect(reason)}"}
    end
  end

  defp activate_proposed(scan, dest, scope, cwd, replace?),
    do: Installer.activate_audited(scan, dest, audit_scope(scope, cwd), replace?)

  # A passing audit is granted for its exact bundle hash. A warn verdict is
  # activated without a load grant: the mutation approval is not an audit
  # approval, so it stays unloadable until an operator approves that bundle.
  defp grant_passed(audit, scope, cwd, name) do
    case BundleAudit.audit_status(audit) do
      :pass -> State.authorize(audit_scope(scope, cwd), name, audit["bundle_hash"], :pass)
      _ -> :ok
    end
  end

  defp read_staged_file(proposed, rel) do
    case Bundle.read_file(proposed, rel) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{rel}: #{reason}"}
    end
  end

  defp refresh_registry(:global, cwd) do
    Registry.refresh(cwd: nil)

    if is_binary(cwd) do
      Registry.refresh(cwd: cwd)
    else
      :ok
    end
  end

  defp refresh_registry(:project, cwd), do: Registry.refresh(cwd: cwd)

  defp safe_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp ok(message, details) do
    %AgentToolResult{
      content: [%TextContent{text: message}],
      details: details
    }
  end

  defp emit_skill_write(
         %AgentToolResult{details: details},
         params,
         tool_call_id,
         cwd,
         telemetry_context
       ) do
    if (details[:action] || Map.get(params, "action")) == "report" do
      :ok
    else
      %{
        result: :ok,
        action: details[:action] || Map.get(params, "action"),
        name: Map.get(params, "name"),
        scope: Map.get(params, "scope", "project"),
        path: details[:path],
        file_path: details[:file_path],
        audit_status: get_in(details, [:audit, :status]),
        lifecycle_state: details[:lifecycle_state],
        replacements: details[:replacements],
        tool_call_id: tool_call_id,
        cwd: cwd
      }
      |> Map.merge(Map.delete(telemetry_context, :write_approval_context))
      |> LemonSkills.Telemetry.skill_write()
    end
  end

  defp emit_skill_write({:error, reason}, params, tool_call_id, cwd, telemetry_context) do
    if Map.get(params, "action") == "report" do
      :ok
    else
      %{
        result: :error,
        action: Map.get(params, "action"),
        name: Map.get(params, "name"),
        scope: Map.get(params, "scope", "project"),
        file_path: Map.get(params, "file_path"),
        reason: reason,
        tool_call_id: tool_call_id,
        cwd: cwd
      }
      |> Map.merge(Map.delete(telemetry_context, :write_approval_context))
      |> LemonSkills.Telemetry.skill_write()
    end
  end

  defp emit_skill_write(_result, _params, _tool_call_id, _cwd, _telemetry_context), do: :ok

  defp telemetry_context(opts) do
    %{
      run_id: Keyword.get(opts, :run_id),
      session_key: Keyword.get(opts, :session_key),
      session_id: Keyword.get(opts, :session_id),
      agent_id: Keyword.get(opts, :agent_id)
    }
  end
end
