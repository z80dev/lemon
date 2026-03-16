defmodule LemonSkills.Migrator do
  @moduledoc """
  Classifies existing global skill installs and back-fills lockfile provenance.

  M2-05 legacy migration path.

  On each run the migrator:

  1. Reads the current global lockfile.
  2. Scans all global skill directories for every installed skill.
  3. Skips skills that already have a non-nil `source_kind` in the lockfile
     (idempotent).
  4. For skills without a record (or with `source_kind: nil`), classifies them:

     | Bucket      | source_kind | trust_level | audit_status | Criteria                         |
     |-------------|-------------|-------------|--------------|----------------------------------|
     | `:builtin`  | `builtin`   | `builtin`   | `pass`       | name matches a repo-bundled skill|
     | `:git`      | `git`       | `community` | `pending`    | `.git/` directory present        |
     | `:local`    | `local`     | `community` | `pass`       | everything else                  |

  5. Writes a minimal provenance record to the global lockfile for each newly
     classified skill.

  Returns `{:ok, %{classified: integer(), skipped: integer()}}`.

  ## Usage

      LemonSkills.Migrator.migrate()

  Safe to call on every boot — exits quickly when nothing needs classifying.
  """

  alias LemonSkills.{Config, Entry, Lockfile, Manifest}

  require Logger

  @priv_subdir "builtin_skills"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run provenance back-fill on all global skill directories.

  Returns `{:ok, %{classified: integer(), skipped: integer()}}`.
  """
  @spec migrate() :: {:ok, %{classified: non_neg_integer(), skipped: non_neg_integer()}}
  def migrate do
    builtin_names = builtin_skill_names()
    {:ok, existing} = read_lockfile_safe()

    results =
      Config.global_skills_dirs()
      |> Enum.flat_map(&scan_skills_dir/1)
      |> Enum.uniq_by(fn {name, _path} -> name end)
      |> Enum.map(fn {name, path} ->
        classify_and_record(name, path, existing, builtin_names)
      end)

    classified = Enum.count(results, &(&1 == :classified))
    skipped = Enum.count(results, &(&1 == :skipped))

    if classified > 0 do
      Logger.info(
        "[Migrator] classified #{classified} skill(s) " <>
          "(#{skipped} already had provenance)"
      )
    end

    {:ok, %{classified: classified, skipped: skipped}}
  rescue
    e ->
      Logger.warning("[Migrator] migration failed: #{Exception.message(e)}")
      {:ok, %{classified: 0, skipped: 0}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp classify_and_record(name, path, existing, builtin_names) do
    if classified?(Map.get(existing, name)) do
      :skipped
    else
      bucket = classify(name, path, builtin_names)
      write_record(name, path, bucket)
      :classified
    end
  end

  # A record is already classified when source_kind is set to a non-empty value.
  defp classified?(nil), do: false
  defp classified?(%{"source_kind" => v}) when is_binary(v) and v != "", do: true
  defp classified?(_), do: false

  defp classify(name, path, builtin_names) do
    cond do
      name in builtin_names -> :builtin
      File.dir?(Path.join(path, ".git")) -> :git
      true -> :local
    end
  end

  defp write_record(name, path, bucket) do
    now = DateTime.utc_now()

    entry =
      Entry.new(path,
        source: :global,
        source_kind: source_kind(bucket),
        source_id: maybe_git_remote(path, bucket),
        trust_level: trust_level(bucket),
        audit_status: audit_status(bucket),
        installed_at: now
      )

    entry =
      case File.read(Entry.skill_file(entry)) do
        {:ok, content} ->
          case Manifest.parse(content) do
            {:ok, manifest, _body} ->
              entry
              |> Entry.with_manifest(manifest)
              |> Map.put(:content_hash, Entry.compute_content_hash(entry))

            :error ->
              entry
          end

        _ ->
          entry
      end

    record = Entry.to_lockfile_record(entry)

    case Lockfile.put(:global, record) do
      :ok ->
        Logger.debug("[Migrator] classified '#{name}' as #{bucket}")

      {:error, reason} ->
        Logger.warning(
          "[Migrator] could not write lockfile record for '#{name}': #{inspect(reason)}"
        )
    end
  end

  defp source_kind(:builtin), do: :builtin
  defp source_kind(:git), do: :git
  defp source_kind(:local), do: :local

  defp trust_level(:builtin), do: :builtin
  defp trust_level(_), do: :community

  defp audit_status(:builtin), do: :pass
  defp audit_status(:git), do: :pending
  defp audit_status(:local), do: :pass

  # For legacy git clones, attempt to read the remote.origin.url from .git/config.
  defp maybe_git_remote(path, :git) do
    git_config_path = Path.join([path, ".git", "config"])

    case File.read(git_config_path) do
      {:ok, content} ->
        case Regex.run(~r/\[remote "origin"\].*?url\s*=\s*([^\n]+)/ms, content) do
          [_, url] -> String.trim(url)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_git_remote(_path, _bucket), do: nil

  # Scan a directory for skill subdirs (subdirs containing SKILL.md).
  defp scan_skills_dir(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.map(fn name -> {name, Path.join(dir, name)} end)
      |> Enum.filter(fn {_name, path} ->
        File.dir?(path) and File.exists?(Path.join(path, "SKILL.md"))
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_lockfile_safe do
    case Lockfile.read(:global) do
      {:ok, records} -> {:ok, records}
      {:error, _} -> {:ok, %{}}
    end
  end

  defp builtin_skill_names do
    case :code.priv_dir(:lemon_skills) do
      {:error, _} ->
        []

      dir ->
        root = dir |> List.to_string() |> Path.join(@priv_subdir)

        if File.dir?(root) do
          root
          |> File.ls!()
          |> Enum.filter(fn name -> File.dir?(Path.join(root, name)) end)
        else
          []
        end
    end
  rescue
    _ -> []
  end
end
