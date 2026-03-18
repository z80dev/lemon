defmodule LemonSkills.Sources.Local do
  @moduledoc """
  Source for skills on the local filesystem.

  A local skill is any directory containing a `SKILL.md` file that exists on
  the current machine. Trust is `:trusted` because the file has already been
  reviewed/placed by the user (no remote download happens).

  The canonical identifier is the absolute path to the skill directory.
  """

  @behaviour LemonSkills.Source

  alias LemonSkills.{Entry, Manifest}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def search(_query, _opts) do
    # Local source has no searchable index — callers must supply a path.
    []
  end

  @impl true
  def inspect(path, _opts) when is_binary(path) do
    skill_file = Path.join(path, "SKILL.md")

    cond do
      not File.dir?(path) ->
        {:error, {:not_a_directory, path}}

      not File.exists?(skill_file) ->
        {:error, {:missing_skill_file, skill_file}}

      true ->
        case File.read(skill_file) do
          {:ok, content} ->
            case Manifest.parse_and_validate(content) do
              {:ok, manifest, _body} -> {:ok, manifest}
              {:error, reason} -> {:error, {:invalid_manifest, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def fetch(source_path, dest_dir, _opts) when is_binary(source_path) do
    skill_file = Path.join(source_path, "SKILL.md")

    cond do
      not File.dir?(source_path) ->
        {:error, {:not_a_directory, source_path}}

      not File.exists?(skill_file) ->
        {:error, {:missing_skill_file, skill_file}}

      true ->
        File.rm_rf(dest_dir)

        case File.cp_r(source_path, dest_dir) do
          {:ok, _} -> {:ok, dest_dir}
          {:error, reason, _path} -> {:error, {:copy_failed, reason}}
        end
    end
  end

  @impl true
  def upstream_hash(path, _opts) when is_binary(path) do
    entry = Entry.new(path)

    case Entry.compute_bundle_hash(entry) do
      nil -> {:error, :file_unreadable}
      hash -> {:ok, hash}
    end
  end

  @impl true
  def trust_level, do: :trusted
end
