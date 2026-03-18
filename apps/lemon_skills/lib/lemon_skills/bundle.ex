defmodule LemonSkills.Bundle do
  @moduledoc """
  Enumerates auditable skill bundle files and computes deterministic bundle hashes.

  Bundle hashing is path-sensitive and content-sensitive. Only the agent-facing
  skill payload is included:

  - `SKILL.md`
  - files under `references/`
  - files under `templates/`
  - files under `scripts/`
  - files under `assets/`

  Hidden files, editor artefacts, and metadata files such as `.draft_meta.json`
  are excluded.
  """

  @allowed_dirs ~w(references templates scripts assets)
  @ignored_suffixes ~w(~ .swp .swo .tmp .temp .bak)

  @type file_info :: %{
          path: String.t(),
          full_path: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          text?: boolean(),
          group: :skill | :references | :templates | :scripts | :assets
        }

  @spec files(String.t()) :: {:ok, [file_info()]} | {:error, term()}
  def files(skill_dir) when is_binary(skill_dir) do
    skill_dir = Path.expand(skill_dir)

    if File.dir?(skill_dir) do
      with {:ok, files} <- collect_root(skill_dir) do
        {:ok, Enum.sort_by(files, & &1.path)}
      end
    else
      {:error, :not_a_directory}
    end
  end

  @spec compute_hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(skill_dir) when is_binary(skill_dir) do
    with {:ok, files} <- files(skill_dir) do
      manifest =
        Enum.map_join(files, "\n", fn file ->
          "#{file.path}\t#{file.sha256}"
        end)

      {:ok, sha256_hex(manifest)}
    end
  end

  @spec review_payload(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def review_payload(skill_dir, opts \\ []) when is_binary(skill_dir) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 32_768)

    with {:ok, files} <- files(skill_dir) do
      {sections, _used} =
        Enum.reduce(files, {[], 0}, fn file, {acc, used} ->
          case File.read(file.full_path) do
            {:ok, bytes} when file.text? ->
              remaining = max(max_bytes - used, 0)
              excerpt = excerpt(bytes, remaining)

              section = """
              ### #{file.path}
              type: text
              bytes: #{file.size}

              #{excerpt}
              """

              {[section | acc], min(max_bytes, used + byte_size(excerpt))}

            {:ok, _bytes} ->
              section = """
              ### #{file.path}
              type: binary
              bytes: #{file.size}
              sha256: #{file.sha256}
              """

              {[section | acc], used}

            {:error, _reason} ->
              section = """
              ### #{file.path}
              type: unreadable
              """

              {[section | acc], used}
          end
        end)

      {:ok,
       """
       Review this skill bundle.

       Bundle files:
       #{Enum.map_join(files, "\n", fn file -> "- #{file.path} (#{file.size} bytes)" end)}

       #{sections |> Enum.reverse() |> Enum.join("\n\n")}
       """}
    end
  end

  defp collect_root(skill_dir) do
    case File.ls(skill_dir) do
      {:ok, entries} ->
        reduce_entries(entries, fn name ->
          cond do
            ignored_name?(name) ->
              {:ok, []}

            name == "SKILL.md" ->
              maybe_file_info(skill_dir, "SKILL.md")

            name in @allowed_dirs ->
              collect_subdir(skill_dir, name)

            true ->
              {:ok, []}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_subdir(skill_dir, rel_dir) do
    full_dir = Path.join(skill_dir, rel_dir)

    case File.lstat(full_dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_not_allowed, rel_dir}}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(full_dir) do
          {:ok, entries} ->
            reduce_entries(entries, fn name ->
              rel_path = Path.join(rel_dir, name)
              full_path = Path.join(skill_dir, rel_path)

              cond do
                ignored_name?(name) ->
                  {:ok, []}

                true ->
                  case File.lstat(full_path) do
                    {:ok, %File.Stat{type: :symlink}} ->
                      {:error, {:symlink_not_allowed, rel_path}}

                    {:ok, %File.Stat{type: :directory}} ->
                      collect_subdir(skill_dir, rel_path)

                    _ ->
                      maybe_file_info(skill_dir, rel_path)
                  end
              end
            end)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_file_info(skill_dir, rel_path) do
    full_path = Path.join(skill_dir, rel_path)

    case File.lstat(full_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_not_allowed, rel_path}}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        case File.read(full_path) do
          {:ok, bytes} ->
            {:ok,
             [
               %{
                 path: rel_path,
                 full_path: full_path,
                 sha256: sha256_hex(bytes),
                 size: size,
                 text?: text_file?(bytes),
                 group: file_group(rel_path)
               }
             ]}

          {:error, _reason} ->
            {:ok, []}
        end

      _ ->
        {:ok, []}
    end
  end

  defp reduce_entries(entries, fun) do
    Enum.reduce_while(entries, {:ok, []}, fn name, {:ok, acc} ->
      case fun.(name) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ignored_name?(name) do
    String.starts_with?(name, ".") or
      Enum.any?(@ignored_suffixes, &String.ends_with?(name, &1))
  end

  defp file_group("SKILL.md"), do: :skill
  defp file_group("references/" <> _), do: :references
  defp file_group("templates/" <> _), do: :templates
  defp file_group("scripts/" <> _), do: :scripts
  defp file_group("assets/" <> _), do: :assets

  defp text_file?(bytes) when is_binary(bytes) do
    not String.contains?(bytes, <<0>>) and String.valid?(bytes)
  end

  defp excerpt(_bytes, remaining) when remaining <= 0, do: "[truncated]"

  defp excerpt(bytes, remaining) do
    if byte_size(bytes) <= remaining do
      bytes
    else
      binary_part(bytes, 0, remaining) <> "\n[truncated]"
    end
  end

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end
end
