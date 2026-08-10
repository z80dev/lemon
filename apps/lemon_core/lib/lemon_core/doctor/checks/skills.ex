defmodule LemonCore.Doctor.Checks.Skills do
  @moduledoc "Checks skill store integrity and directory layout."

  alias LemonCore.Doctor.Check

  @doc """
  Returns a list of Check results covering the local skills store.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    [
      check_skills_dir()
    ]
  end

  defp check_skills_dir do
    path = LemonCore.Paths.home_path("skills")

    cond do
      not File.exists?(path) ->
        Check.skip(
          "skills.directory",
          "Skills directory does not exist yet: #{path} (created on first install)."
        )

      not File.dir?(path) ->
        Check.fail(
          "skills.directory",
          "Expected a directory at #{path} but found a file.",
          "Remove or rename #{path} so Lemon can create the skills directory."
        )

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            skill_dirs = Enum.count(entries, fn e -> File.dir?(Path.join(path, e)) end)

            Check.pass(
              "skills.directory",
              "Skills directory OK: #{skill_dirs} skill(s) installed."
            )

          {:error, reason} ->
            Check.warn(
              "skills.directory",
              "Could not list skills directory #{path}: #{inspect(reason)}.",
              "Check directory permissions."
            )
        end
    end
  end
end
