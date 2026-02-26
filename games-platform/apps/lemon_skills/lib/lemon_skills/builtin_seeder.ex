defmodule LemonSkills.BuiltinSeeder do
  @moduledoc """
  Seeds repository-bundled skills into the user's global skills directory.

  Source of truth (in-repo):
  - `apps/lemon_skills/priv/builtin_skills/<skill-name>/SKILL.md`

  Destination (user config):
  - `~/.lemon/agent/skill/<skill-name>/SKILL.md` (or `LEMON_AGENT_DIR` override)

  This is intentionally conservative:
  - Only copies skills that are missing at the destination.
  - Never overwrites an existing skill directory (treat it as user-owned).
  """

  alias LemonSkills.Config

  require Logger

  @priv_subdir "builtin_skills"

  @spec seed!(keyword()) :: :ok
  def seed!(opts \\ []) do
    enabled? =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:lemon_skills, :seed_builtin_skills, true)
      )

    if enabled?, do: do_seed(), else: :ok
  end

  defp do_seed do
    source_root = builtin_source_root()

    cond do
      is_nil(source_root) ->
        :ok

      not File.dir?(source_root) ->
        :ok

      true ->
        dest_root = Config.global_skills_dir()
        File.mkdir_p!(dest_root)

        source_root
        |> File.ls!()
        |> Enum.map(&Path.join(source_root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.each(fn skill_dir ->
          seed_one(skill_dir, dest_root)
        end)

        :ok
    end
  rescue
    e ->
      Logger.warning("[BuiltinSeeder] failed to seed builtin skills: #{Exception.message(e)}")
      :ok
  end

  defp seed_one(source_skill_dir, dest_root) do
    skill_name = Path.basename(source_skill_dir)
    source_skill_file = Path.join(source_skill_dir, "SKILL.md")
    dest_skill_dir = Path.join(dest_root, skill_name)

    cond do
      not File.regular?(source_skill_file) ->
        Logger.warning(
          "[BuiltinSeeder] skipping builtin skill '#{skill_name}': missing SKILL.md at #{source_skill_file}"
        )

        :ok

      File.dir?(dest_skill_dir) ->
        :ok

      true ->
        case File.cp_r(source_skill_dir, dest_skill_dir) do
          {:ok, _} ->
            :ok

          {:error, reason, path} ->
            Logger.warning(
              "[BuiltinSeeder] failed to copy builtin skill '#{skill_name}' to #{dest_skill_dir}: #{inspect(reason)} at #{path}"
            )

            :ok
        end
    end
  end

  defp builtin_source_root do
    case :code.priv_dir(:lemon_skills) do
      {:error, _} ->
        nil

      dir ->
        dir
        |> List.to_string()
        |> Path.join(@priv_subdir)
    end
  end
end

