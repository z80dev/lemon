defmodule CodingAgent.BrowserProviderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SettingsManager, ToolRegistry}
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir
  @browser_names ToolRegistry.builtin_tool_names()
                 |> Enum.map(&Atom.to_string/1)
                 |> Enum.filter(&String.starts_with?(&1, "browser_"))
  @base [include_extensions: false, include_mcp: false]

  setup do
    keys = [:browser_provider_probe, :browser_provider_lcu_probe]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_core, &1)})
    test_pid = self()

    # Probes run in a process spawned by the resolving caller; report that
    # caller so unrelated processes resolving concurrently are not counted.
    report = fn provider ->
      {:parent, caller} = Process.info(self(), :parent)
      send(test_pid, {:browser_probe, provider, caller})
      {:error, "missing"}
    end

    Application.put_env(:lemon_core, :browser_provider_lcu_probe, fn -> report.("lcu") end)
    Application.put_env(:lemon_core, :browser_provider_probe, report)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_core, key, value)
        {key, :error} -> Application.delete_env(:lemon_core, key)
      end)
    end)
  end

  test "LCU is the only browser surface when selected", %{tmp_dir: root} do
    resolution = %{
      requested: "auto",
      provider: "lcu",
      reason: "LCU relay connected.",
      checks: %{}
    }

    tools =
      ToolRegistry.get_tools(
        root,
        @base ++
          [
            enabled_only: ["browser_tabs", "browser_navigate"],
            browser_provider_resolution: resolution
          ]
      )

    assert tools == []
  end

  test "builds that exclude browser tools never probe the provider", %{tmp_dir: root} do
    assert [_ | _] = ToolRegistry.get_tools(root, @base ++ [disabled: @browser_names])
    assert [_ | _] = ToolRegistry.get_tools(root, @base ++ [enabled_only: ["read"]])

    report = ToolRegistry.tool_conflict_report(root, @base ++ [enabled_only: ["read"]])
    assert report.builtin_count > 0

    for _ <- 1..3, do: assert({:ok, _} = ToolRegistry.get_tool(root, "read", @base))

    assert ToolRegistry.put_browser_provider_resolution(@base ++ [disabled: @browser_names]) ==
             @base ++ [disabled: @browser_names]

    assert probes() == []
  end

  test "a build that includes browser tools probes the auto chain once", %{tmp_dir: root} do
    tools = ToolRegistry.get_tools(root, @base)
    assert Enum.count(tools, &(&1.name in @browser_names)) == length(@browser_names)
    assert probes() == ["lcu", "relay", "local"]

    opts = ToolRegistry.put_browser_provider_resolution(@base)
    assert probes() == ["lcu", "relay", "local"]

    assert [_ | _] = ToolRegistry.get_tools(root, opts)
    assert ToolRegistry.tool_conflict_report(root, opts).builtin_count > length(@browser_names)
    assert {:ok, _} = ToolRegistry.get_tool(root, "browser_navigate", opts)
    assert probes() == []
  end

  test "a session build probes the provider once", %{tmp_dir: root} do
    session =
      start_supervised!(
        {Session,
         [
           cwd: root,
           workspace_dir: Path.join(root, "workspace"),
           model: Mocks.mock_model(),
           stream_fn: Mocks.mock_stream_fn([Mocks.assistant_message("done")]),
           settings_manager: %SettingsManager{
             extension_auto_load_default_paths: false,
             compaction_enabled: false
           }
         ]}
      )

    assert Enum.any?(Session.get_state(session).tools, &(&1.name in @browser_names))
    assert probes(session) == ["lcu", "relay", "local"]
  end

  test "browser descriptions omit the detection reason", %{tmp_dir: root} do
    for provider <- ["relay", "local", nil] do
      reason = "Detection reason for #{inspect(provider)}: relay token missing; driver absent."
      resolution = %{requested: "auto", provider: provider, reason: reason, checks: %{}}

      tools =
        ToolRegistry.get_tools(
          root,
          @base ++ [enabled_only: @browser_names, browser_provider_resolution: resolution]
        )

      assert length(tools) == length(@browser_names)

      for tool <- tools do
        refute tool.description =~ reason
        refute tool.description =~ "auto ->"
      end
    end

    assert probes() == []
  end

  test "a request without an available provider returns the reason", %{tmp_dir: root} do
    reason = "No browser provider is available; install the local browser driver."
    resolution = %{requested: "auto", provider: nil, reason: reason, checks: %{}}
    tool = CodingAgent.Tools.BrowserTabs.tool(root, browser_provider_resolution: resolution)

    assert {:error, ^reason} = tool.execute.("tabs", %{}, nil, nil)
  end

  defp probes(caller \\ self()) do
    receive do
      {:browser_probe, provider, ^caller} -> [provider | probes(caller)]
    after
      50 -> []
    end
  end
end
