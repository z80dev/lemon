defmodule CodingAgent.Tools.Rewind do
  @moduledoc "Collapse the active exploration checkpoint into a retained report."

  def tool(_cwd, opts \\ []) do
    CodingAgent.Tools.Checkpoint.definition(
      "rewind",
      "report",
      "Finish the active checkpoint, replacing exploratory context with a non-empty report. Does not restore files or undo external effects. One rewind per checkpoint.",
      opts
    )
  end
end
