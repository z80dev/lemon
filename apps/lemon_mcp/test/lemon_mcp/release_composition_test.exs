defmodule LemonMCP.ReleaseCompositionTest do
  use ExUnit.Case, async: false

  alias LemonSkills.McpSource

  @umbrella_mix_exs Path.expand("../../../../mix.exs", __DIR__)
  @release_smoke Path.expand("../../../../.github/workflows/release-smoke.yml", __DIR__)
  @runtime_boot_verifier Path.expand("../../../../scripts/verify_release_runtime_boot", __DIR__)
  @runtime_releases [:lemon_runtime_min, :lemon_runtime_full]

  test "runtime releases load the MCP library before its dynamic consumers" do
    releases = umbrella_releases()

    for release <- @runtime_releases do
      applications = get_in(releases, [release, :applications])
      application_names = Keyword.keys(applications)

      assert applications[:lemon_mcp] == :load,
             "#{release} does not assemble :lemon_mcp as a library"

      assert index_of(application_names, :lemon_mcp) < index_of(application_names, :coding_agent),
             "#{release} must load :lemon_mcp before :coding_agent"

      if release == :lemon_runtime_full do
        assert index_of(application_names, :lemon_mcp) <
                 index_of(application_names, :lemon_skills),
               "#{release} must load :lemon_mcp before :lemon_skills"
      end
    end
  end

  test "the assembled library enables MCP feature detection without an application callback" do
    saved_disabled = Application.fetch_env(:lemon_skills, :mcp_disabled)
    saved_disabled_env = System.get_env("LEMON_MCP_DISABLED")

    Application.delete_env(:lemon_skills, :mcp_disabled)
    System.delete_env("LEMON_MCP_DISABLED")

    on_exit(fn ->
      restore_app_env(saved_disabled)
      restore_env(saved_disabled_env)
    end)

    assert Application.spec(:lemon_mcp, :mod) == []
    refute Code.ensure_loaded?(LemonMCP.Application)
    assert Code.ensure_loaded?(LemonMCP.Client)
    assert McpSource.mcp_enabled?()
  end

  test "release smoke evaluates the packaged contract in both runtime profiles" do
    workflow = File.read!(@release_smoke)

    assert workflow =~ ~s(["lemon_runtime_min","lemon_runtime_full"])
    assert workflow =~ "Verify packaged MCP library contract"
    assert workflow =~ "Code.ensure_loaded?(LemonMCP.Client)"
    assert workflow =~ "LemonSkills.McpSource.mcp_enabled?()"
    assert workflow =~ "Application.loaded_applications()"
    assert workflow =~ "Application.started_applications()"
    assert workflow =~ "Application.spec(:lemon_mcp, :mod) == []"
    assert workflow =~ "not Code.ensure_loaded?(LemonMCP.Application)"
  end

  test "artifact boot verification repeats the packaged contract without ambient overrides" do
    verifier = File.read!(@runtime_boot_verifier)

    assert verifier =~ "-u LEMON_MCP_DISABLED"
    assert verifier =~ "Code.ensure_loaded?(LemonMCP.Client)"
    assert verifier =~ "LemonSkills.McpSource.mcp_enabled?()"
    assert verifier =~ "Application.loaded_applications()"
    assert verifier =~ "Application.started_applications()"
    assert verifier =~ "Application.spec(:lemon_mcp, :mod) == []"
    assert verifier =~ "not Code.ensure_loaded?(LemonMCP.Application)"
  end

  defp index_of(applications, application) do
    Enum.find_index(applications, &(&1 == application)) ||
      flunk("missing #{inspect(application)} from release applications")
  end

  # An app test runs with LemonMCP.MixProject as the active project, so inspect
  # the umbrella's literal releases/0 definition rather than the app config.
  defp umbrella_releases do
    {:ok, ast} = @umbrella_mix_exs |> File.read!() |> Code.string_to_quoted()

    {_ast, releases_ast} =
      Macro.prewalk(ast, nil, fn
        {:defp, _meta, [{:releases, _, args}, [do: body]]} = node, _acc when args in [nil, []] ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    assert releases_ast, "no releases/0 found in #{@umbrella_mix_exs}"

    releases_ast |> Code.eval_quoted() |> elem(0)
  end

  defp restore_app_env(:error), do: Application.delete_env(:lemon_skills, :mcp_disabled)

  defp restore_app_env({:ok, value}),
    do: Application.put_env(:lemon_skills, :mcp_disabled, value)

  defp restore_env(nil), do: System.delete_env("LEMON_MCP_DISABLED")
  defp restore_env(value), do: System.put_env("LEMON_MCP_DISABLED", value)
end
