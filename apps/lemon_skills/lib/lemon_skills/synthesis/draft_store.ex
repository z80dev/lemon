defmodule LemonSkills.Synthesis.DraftStore do
  @moduledoc """
  Manages draft skill directories.

  Draft skills live in `~/.lemon/agent/skill_drafts/` (global) or
  `<cwd>/.lemon/skill_drafts/` (project).  Each draft is a self-contained
  directory with:

      skill_drafts/
      └── synth-deploy-to-k8s/
          ├── SKILL.md            # generated skill content
          └── .draft_meta.json    # synthesis provenance (source_doc_id, timestamps)

  ## Usage

      # Write a new draft
      :ok = DraftStore.put(%{key: "synth-deploy-k8s", content: "..."}, global: true)

      # List all drafts
      {:ok, drafts} = DraftStore.list(global: true)

      # Promote a draft to an installed skill
      {:ok, entry} = DraftStore.promote("synth-deploy-k8s", global: true)

      # Delete a draft
      :ok = DraftStore.delete("synth-deploy-k8s", global: true)
  """

  alias LemonSkills.Config
  alias LemonSkills.Installer

  @skill_filename "SKILL.md"
  @meta_filename ".draft_meta.json"

  @type draft_info :: %{
          key: String.t(),
          path: String.t(),
          name: String.t(),
          created_at: String.t() | nil,
          source_doc_id: String.t() | nil,
          has_skill_file: boolean()
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Write a draft to disk.

  `draft` must include `:key` and `:content`.  Optional field `:source_doc_id`
  is stored in the draft metadata.

  ## Options

  - `:global` — write to global draft dir (default: `true`)
  - `:cwd` — project directory for project-scoped drafts
  - `:force` — overwrite an existing draft (default: `false`)
  """
  @spec put(map(), keyword()) :: :ok | {:error, term()}
  def put(draft, opts \\ []) when is_map(draft) do
    key = draft[:key] || draft["key"]
    content = draft[:content] || draft["content"]
    source_doc_id = draft[:source_doc_id] || draft["source_doc_id"]

    if is_nil(key) or is_nil(content) do
      {:error, "draft must include :key and :content"}
    else
      dir = draft_dir(key, opts)
      force = Keyword.get(opts, :force, false)

      if File.dir?(dir) and not force do
        {:error, "draft '#{key}' already exists; pass force: true to overwrite"}
      else
        do_write_draft(dir, key, content, source_doc_id)
      end
    end
  end

  @doc """
  List all drafts in the draft directory.

  Returns `{:ok, [draft_info]}` — an empty list when no drafts exist.
  """
  @spec list(keyword()) :: {:ok, [draft_info()]}
  def list(opts \\ []) do
    dir = drafts_root(opts)

    drafts =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.map(&read_draft_info/1)
          |> Enum.sort_by(& &1.created_at)

        {:error, _} ->
          []
      end

    {:ok, drafts}
  end

  @doc """
  Read a single draft by key.

  Returns `{:ok, %{key, path, content, meta}}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get(key, opts \\ []) do
    dir = draft_dir(key, opts)

    if File.dir?(dir) do
      skill_file = Path.join(dir, @skill_filename)
      meta = read_meta(dir)

      case File.read(skill_file) do
        {:ok, content} ->
          {:ok, %{key: key, path: dir, content: content, meta: meta}}

        {:error, _} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Delete a draft by key.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    dir = draft_dir(key, opts)

    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @doc """
  Promote a draft to an installed skill.

  Calls `LemonSkills.Installer.install/2` with the draft directory path.
  On success, deletes the draft.

  ## Options

  - `:global` — install globally (default: `true`)
  - `:cwd` — project directory for project-scoped install
  - `:force` — overwrite existing installed skill (default: `false`)
  - `:approve` — pre-approve the install (default: `true` since we reviewed)
  """
  @spec promote(String.t(), keyword()) ::
          {:ok, LemonSkills.Entry.t()} | {:error, term()}
  def promote(key, opts \\ []) do
    dir = draft_dir(key, opts)

    unless File.dir?(dir) do
      {:error, "draft '#{key}' not found"}
    else
      install_opts =
        opts
        |> Keyword.put(:approve, Keyword.get(opts, :approve, true))
        |> Keyword.put(:force, Keyword.get(opts, :force, false))

      case Installer.install(dir, install_opts) do
        {:ok, entry} ->
          # Remove the draft after successful promotion
          File.rm_rf(dir)
          {:ok, entry}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Return the path to a draft directory.
  """
  @spec draft_dir(String.t(), keyword()) :: String.t()
  def draft_dir(key, opts \\ []) do
    Path.join(drafts_root(opts), key)
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

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp do_write_draft(dir, key, content, source_doc_id) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, @skill_filename), content) do
      meta = %{
        "key" => key,
        "source_doc_id" => source_doc_id,
        "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "status" => "draft"
      }

      case Jason.encode(meta, pretty: true) do
        {:ok, json} ->
          File.write(Path.join(dir, @meta_filename), json)

        {:error, reason} ->
          {:error, reason}
      end
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
      has_skill_file: has_skill_file
    }
  end

  defp read_meta(dir) do
    meta_file = Path.join(dir, @meta_filename)

    case File.read(meta_file) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, map} -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
