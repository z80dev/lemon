defmodule LemonAutomation.CuratorReferences do
  @moduledoc "Cron references consumed by every skills curator entry point."
  @behaviour LemonSkills.CuratorReferences

  @impl true
  def referenced_skills(names) do
    {:ok, references(LemonAutomation.CronStore.list_jobs(), names)}
  end

  @doc "Match complete skill names in all jobs, including disabled jobs."
  def references(jobs, names) do
    Enum.filter(names, fn name ->
      pattern =
        Regex.compile!(
          "(?<![\\p{L}\\p{N}_-])" <> Regex.escape(name) <> "(?![\\p{L}\\p{N}_-])",
          "u"
        )

      Enum.any?(jobs, fn job ->
        meta = Map.get(job, :meta) || Map.get(job, "meta") || %{}

        explicit =
          Enum.flat_map([:skill, "skill", :skills, "skills"], &List.wrap(Map.get(meta, &1)))

        prompt = Map.get(job, :prompt) || Map.get(job, "prompt")
        name in explicit or (is_binary(prompt) and Regex.match?(pattern, prompt))
      end)
    end)
  end
end
