defmodule Mix.Tasks.Lemon.Skill.Lint do
  use Mix.Task

  alias LemonSkills.Audit.SkillLint

  @shortdoc "Lint skill bundles for manifest compliance and audit cleanliness"
  @moduledoc """
  Validate skill bundles under one or more directories.

  Checks each skill subdirectory for:
    - SKILL.md present
    - Frontmatter parses (valid YAML/TOML)
    - Required fields: name, description (non-empty)
    - Reference paths exist in the skill directory
    - Body is non-empty
    - Audit verdict is not :block (content safety)

  ## Usage

      mix lemon.skill.lint [PATH ...]

  PATH defaults to the builtin skills directory when not specified.

  ## Examples

      mix lemon.skill.lint
      mix lemon.skill.lint ~/.lemon/agent/skill
      mix lemon.skill.lint apps/lemon_skills/priv/builtin_skills ~/.lemon/agent/skill
      mix lemon.skill.lint --strict  # treat :warn issues as failures

  ## Options

    --strict    Treat audit :warn findings as errors (default: false)
    --json      Output results as JSON instead of human-readable text
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, _invalid} =
      OptionParser.parse(args,
        switches: [strict: :boolean, json: :boolean],
        aliases: []
      )

    strict = Keyword.get(opts, :strict, false)
    json_output = Keyword.get(opts, :json, false)

    dirs =
      if paths == [] do
        [builtin_skills_dir()]
      else
        paths
      end

    results =
      dirs
      |> Enum.flat_map(fn dir ->
        if File.dir?(dir) do
          SkillLint.lint_dir(dir)
        else
          Mix.shell().error("Not a directory: #{dir}")
          []
        end
      end)

    if json_output do
      print_json(results)
    else
      print_results(results, strict)
    end

    failures = count_failures(results, strict)

    if failures > 0 do
      Mix.raise("Skill lint failed: #{failures} skill(s) have errors.")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Output
  # ──────────────────────────────────────────────────────────────────────────

  defp print_results(results, strict) do
    total = length(results)
    failures = count_failures(results, strict)

    Enum.each(results, fn result ->
      relevant_issues =
        if strict do
          result.issues
        else
          Enum.filter(result.issues, &(&1.severity == :error))
        end

      if relevant_issues == [] do
        Mix.shell().info("  [ok] #{result.key}")
      else
        Mix.shell().error("  [fail] #{result.key} (#{result.path})")

        Enum.each(relevant_issues, fn issue ->
          prefix = if issue.severity == :error, do: "    ✗", else: "    ⚠"
          Mix.shell().error("#{prefix} [#{issue.code}] #{issue.message}")
        end)
      end
    end)

    if failures == 0 do
      Mix.shell().info("Skill lint: #{total} skill(s) checked, all passed.")
    else
      Mix.shell().error("Skill lint: #{failures}/#{total} skill(s) failed.")
    end
  end

  defp print_json(results) do
    json =
      results
      |> Enum.map(fn r ->
        %{
          key: r.key,
          path: r.path,
          valid: r.valid?,
          issues:
            Enum.map(r.issues, fn i ->
              %{code: i.code, message: i.message, severity: i.severity}
            end)
        }
      end)
      |> Jason.encode!(pretty: true)

    Mix.shell().info(json)
  end

  defp count_failures(results, strict) do
    Enum.count(results, fn result ->
      if strict do
        result.issues != []
      else
        not result.valid?
      end
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp builtin_skills_dir do
    # Resolve from the app's priv directory at runtime
    :code.priv_dir(:lemon_skills)
    |> to_string()
    |> Path.join("builtin_skills")
  end
end
