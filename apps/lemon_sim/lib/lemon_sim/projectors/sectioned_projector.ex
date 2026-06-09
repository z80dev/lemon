defmodule LemonSim.Projectors.SectionedProjector do
  @moduledoc false

  defdelegate project(frame, tools, opts), to: LemonSim.LLM.Projectors.SectionedProjector
end
