defmodule LemonMCP.ReleaseCompositionTest do
  use ExUnit.Case, async: false

  alias LemonSkills.McpSource

  test "the assembled library enables MCP feature detection" do
    saved_disabled = Application.fetch_env(:lemon_skills, :mcp_disabled)
    saved_disabled_env = System.get_env("LEMON_MCP_DISABLED")

    Application.delete_env(:lemon_skills, :mcp_disabled)
    System.delete_env("LEMON_MCP_DISABLED")

    on_exit(fn ->
      restore_app_env(saved_disabled)
      restore_env(saved_disabled_env)
    end)

    assert McpSource.mcp_enabled?()
  end

  defp restore_app_env(:error), do: Application.delete_env(:lemon_skills, :mcp_disabled)

  defp restore_app_env({:ok, value}),
    do: Application.put_env(:lemon_skills, :mcp_disabled, value)

  defp restore_env(nil), do: System.delete_env("LEMON_MCP_DISABLED")
  defp restore_env(value), do: System.put_env("LEMON_MCP_DISABLED", value)
end
