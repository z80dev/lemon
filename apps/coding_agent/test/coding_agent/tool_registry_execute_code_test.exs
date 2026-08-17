defmodule CodingAgent.ToolRegistryExecuteCodeTest do
  @moduledoc """
  Registry-level gating for `execute_code`: it is a config-gated builtin, so a
  disabled workspace must not see it in the catalog at all.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ToolPolicy
  alias CodingAgent.ToolRegistry
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  describe "config gating" do
    test "absent by default -- no settings manager means no execute_code", %{tmp_dir: cwd} do
      refute "execute_code" in names(cwd, [])
      assert {:error, :not_found} = ToolRegistry.get_tool(cwd, "execute_code", base_opts())
    end

    test "present once enabled, and always last so the prefix stays stable", %{tmp_dir: cwd} do
      enabled = names(cwd, enabled_opts())

      assert List.last(enabled) == "execute_code"

      assert Enum.find_index(enabled, &(&1 == "execute_code")) >
               Enum.find_index(enabled, &(&1 == "hashline_edit"))

      assert {:ok, tool} = ToolRegistry.get_tool(cwd, "execute_code", enabled_opts())
      assert tool.name == "execute_code"
    end

    test "enabling it leaves every other tool's schema untouched", %{tmp_dir: cwd} do
      disabled = schemas(cwd, base_opts())
      enabled = schemas(cwd, enabled_opts())

      assert Enum.reject(enabled, &(elem(&1, 0) == "execute_code")) == disabled
    end

    test "kernel settings alone never enable the tool", %{tmp_dir: cwd} do
      opts =
        Keyword.put(
          base_opts(),
          :settings_manager,
          %{tools: %{execute_code: %{kernel_mode: "session", max_live_kernels: 4}}}
        )

      refute "execute_code" in names(cwd, opts)
    end

    test "session mode keeps it last and adds only the reset property", %{tmp_dir: cwd} do
      opts =
        Keyword.put(
          base_opts(),
          :settings_manager,
          %{tools: %{execute_code: %{enabled: true, kernel_mode: "session"}}}
        )

      assert List.last(names(cwd, opts)) == "execute_code"

      assert {:ok, tool} = ToolRegistry.get_tool(cwd, "execute_code", opts)
      assert tool.description =~ "Kernel mode: session"
      assert tool.parameters["properties"]["reset"]["type"] == "boolean"
      assert tool.parameters["required"] == ["script"]

      # The schema change is additive: every other tool's schema is untouched.
      assert Enum.reject(schemas(cwd, opts), &(elem(&1, 0) == "execute_code")) ==
               schemas(cwd, base_opts())
    end

    test "tool_conflict_report/2 counts it as a builtin when enabled", %{tmp_dir: cwd} do
      disabled = ToolRegistry.tool_conflict_report(cwd, base_opts())
      enabled = ToolRegistry.tool_conflict_report(cwd, enabled_opts())

      assert enabled.builtin_count == disabled.builtin_count + 1
      assert enabled.conflicts == []
    end
  end

  describe "policy interaction" do
    test "dangerous profiles hide it", %{tmp_dir: cwd} do
      refute "execute_code" in names(cwd, enabled_opts(tool_policy: profile(:safe_mode)))
      refute "execute_code" in names(cwd, enabled_opts(tool_policy: profile(:read_only)))

      refute "execute_code" in names(
               cwd,
               enabled_opts(tool_policy: profile(:subagent_restricted))
             )
    end

    test "minimal_core keeps it, the same way it keeps bash", %{tmp_dir: cwd} do
      allowed = names(cwd, enabled_opts(tool_policy: profile(:minimal_core)))

      assert "execute_code" in allowed
      assert "bash" in allowed
    end
  end

  describe "approval wrapping" do
    test "approval runs before the script, and a denial never starts it", %{tmp_dir: cwd} do
      test = self()

      opts =
        enabled_opts(
          tool_policy: ToolPolicy.custom(require_approval: ["execute_code"]),
          approval_context: %{
            timeout_ms: 30_000,
            approval_request_fun: fn request ->
              send(test, {:approval_requested, request.tool})
              {:ok, :denied}
            end
          },
          script_runner: fn _command, _cwd, _opts ->
            flunk("the script must not run when approval is denied")
          end
        )

      assert {:ok, tool} = ToolRegistry.get_tool(cwd, "execute_code", opts)

      result = tool.execute.("call-1", %{"script" => "print(1)"}, nil, nil)

      assert_received {:approval_requested, "execute_code"}
      assert %AgentToolResult{details: %{denied: true}} = result
      assert [%TextContent{text: text}] = result.content
      assert text =~ "denied"
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp names(cwd, opts), do: cwd |> ToolRegistry.get_tools(opts) |> Enum.map(& &1.name)

  defp schemas(cwd, opts) do
    cwd
    |> ToolRegistry.get_tools(opts)
    |> Enum.map(&{&1.name, &1.description, &1.parameters})
  end

  defp base_opts, do: [include_extensions: false, include_mcp: false]

  defp enabled_opts(extra \\ []) do
    base_opts()
    |> Keyword.merge(settings_manager: %{tools: %{execute_code: %{enabled: true}}})
    |> Keyword.merge(extra)
  end

  defp profile(name), do: ToolPolicy.from_profile(name)
end
