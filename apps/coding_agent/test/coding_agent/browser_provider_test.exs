defmodule CodingAgent.BrowserProviderTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "LCU is the only browser surface when selected", %{tmp_dir: root} do
    resolution = %{
      requested: "auto",
      provider: "lcu",
      reason: "LCU relay connected.",
      checks: %{}
    }

    tools =
      CodingAgent.ToolRegistry.get_tools(root,
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["browser_tabs", "browser_navigate"],
        browser_provider_resolution: resolution
      )

    assert tools == []
  end

  @tag :tmp_dir
  test "browser descriptions identify the resolved surface and unavailable reason", %{
    tmp_dir: root
  } do
    for {provider, reason} <- [
          {"relay", "Lemon extension connected."},
          {"local", "Managed Chrome available."},
          {nil, "No browser provider is available."}
        ] do
      resolution = %{requested: "auto", provider: provider, reason: reason, checks: %{}}

      tools =
        CodingAgent.ToolRegistry.get_tools(root,
          include_extensions: false,
          include_mcp: false,
          enabled_only: ["browser_tabs"],
          browser_provider_resolution: resolution
        )

      assert [tool] = tools
      assert tool.description =~ "Browser provider: auto -> #{provider || "none"}"
      assert tool.description =~ reason
    end
  end
end
