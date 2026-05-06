defmodule LemonSkills.Tools.SkillManage do
  @moduledoc """
  Agent-facing skill authoring and maintenance tool.

  This is Lemon's procedural-memory write path: agents can turn learned
  workflows into local skills, then maintain those skills with small edits and
  supporting files. Writes are scoped to Lemon skill directories and audited
  before they are exposed through the registry.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonSkills.{Config, Manifest, Registry}
  alias LemonSkills.Audit.BundleAudit

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
    telemetry_context = telemetry_context(opts)

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
              "restore"
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
          }
        },
        "required" => ["action", "name"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, telemetry_context)
    }
  end

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
             {:ok, name} <- required_string(params, "name"),
             :ok <- validate_name(name),
             {:ok, scope} <- parse_scope(Map.get(params, "scope", "project")),
             {:ok, root} <- skills_root(scope, cwd) do
          dispatch(action, name, params, scope, root, cwd)
        end
      end

    emit_skill_write(result, params, tool_call_id, cwd, telemetry_context)
    result
  end

  defp dispatch("create", name, params, scope, root, cwd) do
    with {:ok, content} <- required_string(params, "content", preserve?: true),
         :ok <- validate_skill_content(content),
         {:ok, dir} <- new_skill_dir(root, name),
         :ok <- File.mkdir_p(dir),
         :ok <- write_new_skill_file(dir, content),
         {:ok, audit} <- audit_or_rollback(dir, audit_scope(scope, cwd), name, {:dir, dir}),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' created at #{dir}.", %{action: "create", path: dir, audit: audit})
    end
  end

  defp dispatch("edit", name, params, scope, root, cwd) do
    with {:ok, content} <- required_string(params, "content", preserve?: true),
         :ok <- validate_skill_content(content),
         {:ok, dir} <- existing_skill_dir(root, name),
         skill_file = Path.join(dir, "SKILL.md"),
         {:ok, original} <- File.read(skill_file),
         :ok <- atomic_write(skill_file, content),
         {:ok, audit} <-
           audit_or_rollback(dir, audit_scope(scope, cwd), name, {skill_file, original}),
         :ok <- refresh_registry(scope, cwd) do
      ok("Skill '#{name}' updated.", %{action: "edit", path: dir, audit: audit})
    end
  end

  defp dispatch("patch", name, params, scope, root, cwd) do
    with {:ok, old_string} <- required_string(params, "old_string", preserve?: true),
         {:ok, new_string} <-
           required_string(params, "new_string", allow_empty?: true, preserve?: true),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, target} <- target_file(dir, Map.get(params, "file_path")),
         :ok <- reject_symlink_path(dir, target),
         {:ok, original} <- File.read(target),
         {:ok, updated, replacements} <-
           patch_content(
             original,
             old_string,
             new_string,
             truthy?(Map.get(params, "replace_all"))
           ),
         :ok <- validate_target_content(target, dir, updated),
         :ok <- atomic_write(target, updated),
         {:ok, audit} <- audit_or_rollback(dir, audit_scope(scope, cwd), name, {target, original}),
         :ok <- refresh_registry(scope, cwd) do
      rel = Path.relative_to(target, dir)

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
         {:ok, _} <- File.rm_rf(dir),
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
         {:ok, target} <- target_file(dir, file_path),
         :ok <- reject_symlink_path(dir, target),
         original <- read_optional(target),
         :ok <- atomic_write(target, file_content),
         {:ok, audit} <- audit_or_rollback(dir, audit_scope(scope, cwd), name, {target, original}),
         :ok <- refresh_registry(scope, cwd) do
      ok("File '#{Path.relative_to(target, dir)}' written to skill '#{name}'.", %{
        action: "write_file",
        path: dir,
        file_path: Path.relative_to(target, dir),
        audit: audit
      })
    end
  end

  defp dispatch("remove_file", name, params, scope, root, cwd) do
    with {:ok, file_path} <- required_string(params, "file_path"),
         {:ok, dir} <- existing_skill_dir(root, name),
         {:ok, target} <- target_file(dir, file_path),
         :ok <- reject_symlink_path(dir, target),
         true <-
           File.regular?(target) || {:error, "File not found: #{Path.relative_to(target, dir)}"},
         {:ok, original} <- File.read(target),
         :ok <- File.rm(target),
         {:ok, audit} <- audit_or_rollback(dir, audit_scope(scope, cwd), name, {target, original}),
         :ok <- refresh_registry(scope, cwd) do
      ok("File '#{Path.relative_to(target, dir)}' removed from skill '#{name}'.", %{
        action: "remove_file",
        path: dir,
        file_path: Path.relative_to(target, dir),
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

  defp dispatch(action, _name, _params, _scope, _root, _cwd) do
    {:error,
     "Unknown action '#{action}'. Use create, edit, patch, delete, write_file, remove_file, pin, unpin, archive, or restore."}
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

  defp skills_root(:global, _cwd), do: {:ok, Config.global_skills_dir()}

  defp skills_root(:project, cwd) when is_binary(cwd) and cwd != "",
    do: {:ok, Config.project_skills_dir(cwd)}

  defp skills_root(:project, _cwd), do: {:error, "project scope requires cwd"}

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

  defp target_file(dir, nil), do: {:ok, Path.join(dir, "SKILL.md")}
  defp target_file(dir, ""), do: {:ok, Path.join(dir, "SKILL.md")}

  defp target_file(dir, file_path) when is_binary(file_path) do
    parts = Path.split(file_path)

    cond do
      Path.type(file_path) == :absolute or ".." in parts ->
        {:error, "file_path must be relative and may not contain '..'"}

      parts == [] or hd(parts) not in @allowed_support_dirs ->
        {:error, "file_path must be under one of: #{Enum.join(@allowed_support_dirs, ", ")}"}

      length(parts) < 2 ->
        {:error, "file_path must include a filename under #{hd(parts)}/"}

      true ->
        target = Path.expand(Path.join(dir, file_path))
        expanded_dir = Path.expand(dir)

        if target == expanded_dir or not String.starts_with?(target, expanded_dir <> "/") do
          {:error, "file_path escapes the skill directory"}
        else
          {:ok, target}
        end
    end
  end

  defp target_file(_dir, _), do: {:error, "file_path must be a string"}

  defp validate_target_content(target, dir, content) do
    if Path.expand(target) == Path.expand(Path.join(dir, "SKILL.md")) do
      validate_skill_content(content)
    else
      validate_supporting_file_size(content)
    end
  end

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

  defp audit_or_rollback(dir, audit_scope, name, rollback) do
    case BundleAudit.audit(dir, audit_scope, name, kind: :skill, force: true) do
      {:ok, audit} ->
        case BundleAudit.audit_status(audit) do
          :block ->
            rollback(rollback)
            {:error, "Skill blocked by security audit: #{format_findings(audit)}"}

          _ ->
            {:ok, summarize_audit(audit)}
        end

      {:error, reason} ->
        rollback(rollback)
        {:error, "Skill audit failed: #{inspect(reason)}"}
    end
  end

  defp audit_scope(:global, _cwd), do: :global
  defp audit_scope(:project, cwd), do: {:project, cwd}

  defp usage_opts(:global, _cwd), do: [scope: :global]
  defp usage_opts(:project, cwd), do: [scope: :project, cwd: cwd]

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

  defp rollback({:dir, dir}), do: File.rm_rf(dir)
  defp rollback({path, nil}), do: File.rm(path)
  defp rollback({path, content}), do: atomic_write(path, content)

  defp refresh_registry(:global, cwd) do
    Registry.refresh(cwd: nil)

    if is_binary(cwd) do
      Registry.refresh(cwd: cwd)
    else
      :ok
    end
  end

  defp refresh_registry(:project, cwd), do: Registry.refresh(cwd: cwd)

  defp read_optional(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    else
      nil
    end
  end

  defp safe_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp reject_symlink_path(dir, target) do
    dir = Path.expand(dir)
    target = Path.expand(target)

    dir
    |> symlink_check_paths(target)
    |> Enum.find_value(:ok, fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:error, "refusing to write through symlink: #{path}"}

        _ ->
          nil
      end
    end)
  end

  defp symlink_check_paths(dir, target) do
    target
    |> Path.relative_to(dir)
    |> Path.split()
    |> Enum.scan(dir, &Path.join(&2, &1))
    |> Enum.reject(&(&1 == target and not File.exists?(&1)))
  end

  defp write_new_skill_file(dir, content) do
    case atomic_write(Path.join(dir, "SKILL.md"), content) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm_rf(dir)
        {:error, reason}
    end
  end

  defp atomic_write(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp.#{System.unique_integer([:positive])}"
      )

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
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
    |> Map.merge(telemetry_context)
    |> LemonSkills.Telemetry.skill_write()
  end

  defp emit_skill_write({:error, reason}, params, tool_call_id, cwd, telemetry_context) do
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
    |> Map.merge(telemetry_context)
    |> LemonSkills.Telemetry.skill_write()
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
