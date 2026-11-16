defmodule CodingAgent.Tools.CodeMode.Wait do
  @moduledoc false

  def tool(cwd, opts), do: CodingAgent.Tools.CodeMode.wait_tool(cwd, opts)
end
