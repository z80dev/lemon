defmodule LemonSim.Projectors.Toolkit do
  @moduledoc false

  defdelegate render_sections(sections, opts \\ []), to: LemonSim.LLM.Projectors.Toolkit
  defdelegate normalize_events(events), to: LemonSim.LLM.Projectors.Toolkit
  defdelegate normalize_plan_steps(steps), to: LemonSim.LLM.Projectors.Toolkit
  defdelegate summarize_tools(tools), to: LemonSim.LLM.Projectors.Toolkit
  defdelegate stable_json(value), to: LemonSim.LLM.Projectors.Toolkit
end
