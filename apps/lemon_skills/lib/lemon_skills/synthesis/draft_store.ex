defmodule LemonSkills.Synthesis.DraftStore do
  @moduledoc false

  # Manages draft skill directories.
  #
  # Draft skills live in `~/.lemon/agent/skill_drafts/` (global) or
  # `<cwd>/.lemon/skill_drafts/` (project).  Each draft is a self-contained
  # directory with:
  #
  #     skill_drafts/
  #     ├── synth-deploy-to-k8s/
  #     │   └── SKILL.md                      # generated skill content
  #     └── .synth-deploy-to-k8s.draft_meta.json  # synthesis provenance
  #
  # The metadata file sits beside the draft bundle, never inside it: a bundle
  # holds only auditable skill layout entries (see `LemonSkills.Bundle`).
  #
  # Usage
  #
  #     # Write a new draft
  #     :ok = DraftStore.put(%{key: "synth-deploy-k8s", content: "..."}, global: true)
  #
  #     # List all drafts
  #     {:ok, drafts} = DraftStore.list(global: true)
  #
  #     # Promote a draft to an installed skill
  #     {:ok, entry} = DraftStore.promote("synth-deploy-k8s", global: true)
  #
  #     # Delete a draft
  #     :ok = DraftStore.delete("synth-deploy-k8s", global: true)

  alias LemonSkills.Config
  alias LemonSkills.Installer
  alias LemonSkills.Audit.State

  @skill_filename "SKILL.md"
  @legacy_meta_filename ".draft_meta.json"
  @key_re ~r/^[a-z0-9][a-z0-9._-]*$/

  # Metadata fields a legacy in-bundle file may carry over; audit verdicts and
  # approval flags are never taken from bundle content.
  @descriptive_meta_keys ~w(key name created_at status source_doc_id source_digest source_provenance source_text_redacted)

  @type draft_info :: %{
          key: String.t(),
          path: String.t(),
          name: String.t(),
          created_at: String.t() | nil,
          source_doc_id: String.t() | nil,
          has_skill_file: boolean(),
          audit_status: String.t() | nil,
          approval_required: boolean()
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Write a draft to disk.

  `draft` must include `:key` and `:content`. Optional `:source_doc_id`,
  `:source_digest`, and hashed `:source_provenance` fields are stored in the
  draft metadata.

  ## Options

  - `:global` — write to global draft dir (default: `true`)
  - `:cwd` — project directory for project-scoped drafts
  - `:force` — overwrite an existing draft (default: `false`)
  """
  @spec put(map(), keyword()) :: :ok | {:error, term()}
  def put(draft, opts \\ []) when is_map(draft) do
    key = draft[:key] || draft["key"]
    content = draft[:content] || draft["content"]

    if is_nil(key) or is_nil(content) do
      {:error, "draft must include :key and :content"}
    else
      with {:ok, dir} <- draft_dir(key, opts) do
        force = Keyword.get(opts, :force, false)

        if File.dir?(dir) and not force do
          {:error, "draft '#{key}' already exists; pass force: true to overwrite"}
        else
          do_write_draft(dir, key, content, draft)
        end
      end
    end
  end

  @doc """
  Create a draft only when its exact destination directory is absent.

  The directory claim uses `File.mkdir/1`, so concurrent reviewers cannot
  overwrite one another between a fresh plan and confirmation.
  """
  @spec put_new(map(), keyword()) :: :ok | {:error, :already_exists | term()}
  def put_new(draft, opts \\ []) when is_map(draft) do
    key = draft[:key] || draft["key"]
    content = draft[:content] || draft["content"]

    if is_nil(key) or is_nil(content) do
      {:error, "draft must include :key and :content"}
    else
      with {:ok, dir} <- draft_dir(key, opts),
           :ok <- File.mkdir_p(Path.dirname(dir)) do
        case claim_directory(dir) do
          :ok ->
            case do_write_draft(dir, key, content, draft) do
              :ok ->
                :ok

              {:error, _} = error ->
                _ = remove_draft(key, opts)
                error
            end

          {:error, :already_exists} ->
            {:error, :already_exists}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  @doc """
  List all drafts in the draft directory.

  Returns `{:ok, [draft_info]}` — an empty list when no drafts exist. Entries
  that are not valid draft keys or are symlinks are skipped, and a symlinked
  drafts root lists nothing.
  """
  @spec list(keyword()) :: {:ok, [draft_info()]}
  def list(opts \\ []) do
    dir = drafts_root(opts)

    drafts =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.flat_map(fn key ->
            case existing_draft_dir(key, opts) do
              {:ok, path} -> [read_draft_info(path)]
              {:error, _} -> []
            end
          end)
          |> Enum.sort_by(& &1.created_at)

        {:error, _} ->
          []
      end

    {:ok, drafts}
  end

  @doc """
  Read a single draft by key.

  Returns `{:ok, %{key, path, content, meta}}`, `{:error, :not_found}`, or the
  `draft_dir/2` validation error.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def get(key, opts \\ []) do
    with {:ok, dir} <- existing_draft_dir(key, opts) do
      skill_file = Path.join(dir, @skill_filename)
      meta = read_meta(dir)

      case File.read(skill_file) do
        {:ok, content} ->
          {:ok, %{key: key, path: dir, content: content, meta: meta}}

        {:error, _} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Delete a draft by key.

  The key and the drafts-root boundary are validated, and the draft must be a
  real directory (not a symlink) immediately before it is removed.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []), do: remove_draft(key, opts)

  @doc """
  Promote a draft to an installed skill.

  Calls `LemonSkills.Installer.promote_draft/2` with the draft directory: the
  draft is staged, freshly audited, and activated only after an explicit
  approval bound to that audited bundle hash. Draft metadata never approves a
  promotion. On success, deletes the draft.

  ## Options

  - `:global` — install globally (default: `true`)
  - `:cwd` — project directory for project-scoped install
  - `:force` — overwrite existing installed skill (default: `false`)
  - `:session_key`, `:agent_id`, `:run_id` — approval routing context
  """
  @spec promote(String.t(), keyword()) ::
          {:ok, LemonSkills.Entry.t()} | {:error, term()}
  def promote(key, opts \\ []) do
    case existing_draft_dir(key, opts) do
      {:ok, dir} ->
        install_opts = Keyword.put(opts, :force, Keyword.get(opts, :force, false))

        # Remove the draft after successful promotion, re-validating its path.
        with :ok <- migrate_legacy_meta(dir),
             {:ok, entry} <- Installer.promote_draft(dir, install_opts),
             :ok <- remove_draft(key, opts) do
          {:ok, entry}
        end

      {:error, :not_found} ->
        {:error, "draft '#{key}' not found"}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Return the metadata file path for a draft directory. It sits beside the
  draft bundle so the bundle holds only auditable skill files.
  """
  @spec meta_path(String.t()) :: String.t()
  def meta_path(dir) do
    Path.join(Path.dirname(dir), ".#{Path.basename(dir)}.draft_meta.json")
  end

  @doc """
  Return the path to a draft directory.

  This is the single choke point for draft paths: `key` must match
  `^[a-z0-9][a-z0-9._-]*$`, and no path component between the trusted base
  (the agent dir, or the project `cwd`) and the draft directory may be a
  symlink or a non-directory. The draft directory itself may be absent.
  """
  @spec draft_dir(term(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_draft_key | :unsafe_draft_path}
  def draft_dir(key, opts \\ []) do
    with :ok <- validate_key(key),
         {:ok, base, parts} <- root_parts(opts),
         :ok <- real_directories(base, parts ++ [key]) do
      {:ok, Path.join([base | parts] ++ [key])}
    end
  end

  @doc """
  Return the root drafts directory.
  """
  @spec drafts_root(keyword()) :: String.t()
  def drafts_root(opts \\ []) do
    global = Keyword.get(opts, :global, true)
    cwd = Keyword.get(opts, :cwd)

    if global or is_nil(cwd) do
      Config.global_draft_skills_dir()
    else
      Config.project_draft_skills_dir(cwd)
    end
  end

  @doc """
  Merge persisted audit data into the draft metadata file.
  """
  @spec record_audit(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def record_audit(key, audit_record, opts \\ []) when is_binary(key) and is_map(audit_record) do
    with {:ok, dir} <- existing_draft_dir(key, opts) do
      meta =
        dir
        |> read_meta()
        |> Map.merge(%{
          "audit_status" => audit_record["final_verdict"],
          "audit_findings" => audit_record["combined_findings"] || [],
          "approval_required" => audit_record["approval_required"] || false,
          "bundle_hash" => audit_record["bundle_hash"],
          "audit_fingerprint" => audit_record["audit_fingerprint"],
          "audited_at" => audit_record["scanned_at"]
        })

      write_meta(dir, meta)
    end
  end

  # ── Path validation ─────────────────────────────────────────────────────────

  defp validate_key(key) when is_binary(key) do
    if Regex.match?(@key_re, key), do: :ok, else: {:error, :invalid_draft_key}
  end

  defp validate_key(_key), do: {:error, :invalid_draft_key}

  # The trusted base is the agent dir (global) or the project cwd; only the
  # components below it are owned by the draft store and checked for symlinks.
  defp root_parts(opts) do
    base =
      case scope(opts) do
        :global -> Config.agent_dir()
        {:project, cwd} -> cwd
      end

    base = Path.expand(base)
    relative = opts |> drafts_root() |> Path.expand() |> Path.relative_to(base)

    if Path.type(relative) == :relative and relative != "." do
      {:ok, base, Path.split(relative)}
    else
      {:error, :unsafe_draft_path}
    end
  end

  defp real_directories(_parent, []), do: :ok

  defp real_directories(parent, [part | rest]) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> real_directories(path, rest)
      {:error, :enoent} -> :ok
      _ -> {:error, :unsafe_draft_path}
    end
  end

  defp existing_draft_dir(key, opts) do
    with {:ok, dir} <- draft_dir(key, opts) do
      case File.lstat(dir) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, dir}
        {:error, :enoent} -> {:error, :not_found}
        _ -> {:error, :unsafe_draft_path}
      end
    end
  end

  # Re-validates the key, the root chain and the leaf right before `rm_rf`;
  # `File.rm_rf/1` itself unlinks nested symlinks without following them.
  # An already-absent draft is not an error.
  #
  # Remaining window: validation and removal are separate pathname walks, so a
  # concurrent writer that swaps an ancestor (`.lemon`, `skill_drafts`) for a
  # symlink between the last `lstat` and `rm_rf` can still redirect removal.
  # Closing it needs descriptor-relative (`openat`/`unlinkat`) deletion, which
  # is tracked as a shared filesystem-boundary finding.
  defp remove_draft(key, opts) do
    result =
      case existing_draft_dir(key, opts) do
        {:ok, dir} -> with :ok <- rm_rf(dir), do: rm_meta(dir)
        {:error, :not_found} -> :ok
        {:error, _} = error -> error
      end

    if result == :ok, do: State.delete(scope(opts), :draft, key)
    result
  end

  defp rm_rf(dir) do
    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp rm_meta(dir) do
    case File.rm(meta_path(dir)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp do_write_draft(dir, key, content, draft) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, @skill_filename), content) do
      meta =
        %{
          "key" => key,
          "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "status" => "draft"
        }
        |> put_present("source_doc_id", draft[:source_doc_id] || draft["source_doc_id"])
        |> put_present("source_digest", draft[:source_digest] || draft["source_digest"])
        |> put_present(
          "source_provenance",
          draft[:source_provenance] || draft["source_provenance"]
        )
        |> put_present(
          "source_text_redacted",
          draft[:source_text_redacted] || draft["source_text_redacted"]
        )

      write_meta(dir, meta)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp claim_directory(dir) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :already_exists}
      error -> error
    end
  end

  defp read_draft_info(dir) do
    key = Path.basename(dir)
    meta = read_meta(dir)
    has_skill_file = File.regular?(Path.join(dir, @skill_filename))

    %{
      key: key,
      path: dir,
      name: meta["name"] || key,
      created_at: meta["created_at"],
      source_doc_id: meta["source_doc_id"],
      has_skill_file: has_skill_file,
      audit_status: meta["audit_status"],
      approval_required: truthy?(meta["approval_required"])
    }
  end

  # Drafts written before the metadata moved beside the bundle keep a legacy
  # in-bundle file. It lives inside bundle content, so only its descriptive
  # fields are read, and they are moved out on the next write or promotion.
  defp read_meta(dir) do
    case read_meta_file(meta_path(dir)) do
      :missing -> dir |> legacy_meta_path() |> read_meta_file() |> legacy_descriptive()
      meta -> meta
    end
  end

  defp read_meta_file(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        :missing
    end
  end

  defp legacy_meta_path(dir), do: Path.join(dir, @legacy_meta_filename)

  defp legacy_descriptive(:missing), do: %{}
  defp legacy_descriptive(meta), do: Map.take(meta, @descriptive_meta_keys)

  defp migrate_legacy_meta(dir) do
    if File.exists?(legacy_meta_path(dir)), do: write_meta(dir, read_meta(dir)), else: :ok
  end

  defp write_meta(dir, meta) do
    case Jason.encode(meta, pretty: true) do
      {:ok, json} ->
        with :ok <- File.write(meta_path(dir), json) do
          case File.rm(Path.join(dir, @legacy_meta_filename)) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scope(opts) do
    if Keyword.get(opts, :global, true) or is_nil(Keyword.get(opts, :cwd)) do
      :global
    else
      {:project, Keyword.fetch!(opts, :cwd)}
    end
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
