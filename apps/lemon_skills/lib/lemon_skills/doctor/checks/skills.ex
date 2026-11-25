defmodule LemonSkills.Doctor.Checks.Skills do
  @moduledoc """
  Checks the global skills directory (`LemonSkills.Config.global_skills_dir/0`)
  and the `skills.json` skill state files (global, and the project's under
  `:project_dir`).

  Registered with the `LemonCore.Doctor` framework via
  `config :lemon_core, :doctor_checks, [__MODULE__]`.
  """

  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.Redaction
  alias LemonSkills.Config

  @doc """
  Returns the Check results for the global skills directory and skill state.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    [
      check_skills_dir(Config.global_skills_dir()),
      check_state(Keyword.get(opts, :project_dir, File.cwd!()))
    ]
  end

  # Doctor output is shared, so the directory is shown as a path label.
  defp check_skills_dir(path) do
    label = Redaction.path_label(path)

    cond do
      not File.exists?(path) ->
        Check.skip(
          "skills.directory",
          "Skills directory does not exist yet: #{label} (created on first install)."
        )

      not File.dir?(path) ->
        Check.fail(
          "skills.directory",
          "Expected a directory at #{label} but found a file.",
          "Remove or rename #{label} so Lemon can create the skills directory."
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
              "Could not list skills directory #{label}: #{inspect(reason)}.",
              "Check directory permissions."
            )
        end
    end
  end

  # An unreadable state file hides every skill (fail closed), so it fails the
  # check. Settings left in skills.json are ignored, so they warn.
  defp check_state(project_dir) do
    scopes = [{:global, Config.global_config_file()}, project_scope(project_dir)]

    results =
      for {scope, path} <- scopes, not is_nil(scope) do
        kind = if scope == :global, do: "global", else: "project"
        {"#{kind} skills.json #{Redaction.path_label(path)}", Config.read_state(scope)}
      end

    failures = for {label, {:error, {:skills_state, _, reason}}} <- results, do: {label, reason}

    ignored =
      for {label, {:ok, state}} <- results,
          keys = Map.keys(state) -- ["disabled"],
          keys != [],
          do: {label, keys}

    cond do
      failures != [] ->
        Check.fail(
          "skills.state",
          "Skill state is unusable, so every skill is hidden: " <>
            Enum.map_join(failures, "; ", fn {label, reason} -> "#{label} (#{reason})" end) <>
            ".",
          "Repair the file as a JSON object whose \"disabled\" value is a list of skill " <>
            "keys, or remove it to enable every skill."
        )

      ignored != [] ->
        Check.warn(
          "skills.state",
          "skills.json holds state only; settings there are ignored: " <>
            Enum.map_join(ignored, "; ", fn {label, keys} ->
              "#{label} (#{ignored_summary(keys)})"
            end) <> ".",
          "Move learning_nudge settings to [skills.learning_nudge] in config.toml and " <>
            "remove the other keys from skills.json."
        )

      true ->
        Check.pass("skills.state", "Skill state OK.")
    end
  end

  defp project_scope(project_dir) when is_binary(project_dir) do
    project_dir = Path.expand(project_dir)
    {{:project, project_dir}, Config.project_config_file(project_dir)}
  end

  defp project_scope(_project_dir), do: {nil, nil}

  # Key names are file content: name only the known legacy settings key.
  defp ignored_summary(keys) do
    {nudge, others} = Enum.split_with(keys, &(&1 == "learning_nudge"))
    named = if nudge == [], do: [], else: ["learning_nudge"]
    counted = if others == [], do: [], else: ["#{length(others)} other key(s)"]
    Enum.join(named ++ counted, ", ")
  end
end
