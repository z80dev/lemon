defmodule LemonSkills.Sources.Builtin do
  @moduledoc """
  Source for repository-bundled (builtin) skills.

  Builtin skills are shipped inside the application's `priv/builtin_skills`
  directory. They carry the highest trust level (`:builtin`) and cannot be
  fetched from a remote; they are installed by `LemonSkills.BuiltinSeeder`.

  The canonical identifier for a builtin source is always `nil` — there is
  nothing meaningful to point at externally.
  """

  @behaviour LemonSkills.Source

  alias LemonSkills.{Entry, Manifest}

  @priv_subdir "builtin_skills"

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def search(_query, _opts) do
    # Enumerate skills from priv/builtin_skills and return light stubs.
    case builtin_root() do
      nil ->
        []

      root ->
        root
        |> list_skill_dirs()
        |> Enum.map(&dir_to_result/1)
    end
  end

  @impl true
  def inspect(_id, _opts) do
    case builtin_root() do
      nil -> {:error, :priv_not_found}
      root -> {:ok, %{"root" => root, "skills" => list_skill_dirs(root)}}
    end
  end

  @impl true
  def fetch(_id, _dest_dir, _opts) do
    # Builtin skills are seeded by BuiltinSeeder, not fetched on demand.
    {:error, :use_builtin_seeder}
  end

  @impl true
  def upstream_hash(_id, _opts) do
    # No remote upstream for builtin skills.
    {:error, :unsupported}
  end

  @impl true
  def trust_level, do: :builtin

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp builtin_root do
    case :code.priv_dir(:lemon_skills) do
      {:error, _} -> nil
      dir -> dir |> List.to_string() |> Path.join(@priv_subdir)
    end
  end

  defp list_skill_dirs(root) do
    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.map(&Path.join(root, &1))
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp dir_to_result(dir) do
    entry = Entry.new(dir, source: :global, source_kind: :builtin, trust_level: :builtin)

    entry =
      case File.read(Entry.skill_file(entry)) do
        {:ok, content} ->
          case Manifest.parse_and_validate(content) do
            {:ok, manifest, _} -> Entry.with_manifest(entry, manifest)
            {:error, _reason} -> entry
          end

        _ ->
          entry
      end

    %{
      entry: entry,
      source: :builtin,
      validated: true,
      url: dir
    }
  end
end
