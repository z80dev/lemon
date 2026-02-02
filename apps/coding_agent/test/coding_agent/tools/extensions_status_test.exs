defmodule CodingAgent.Tools.ExtensionsStatusTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.ExtensionsStatus
  alias AgentCore.Types.AgentToolResult

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns a valid AgentTool struct", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir)

      assert tool.name == "extensions_status"
      assert is_binary(tool.description)
      assert tool.label == "Extensions Status"
      assert is_function(tool.execute, 4)
      assert is_map(tool.parameters)
    end

    test "tool has include_details parameter" do
      tool = ExtensionsStatus.tool("/tmp")

      props = tool.parameters["properties"]
      assert Map.has_key?(props, "include_details")
      assert props["include_details"]["type"] == "boolean"
    end
  end

  describe "execute/6" do
    test "returns result without session_id", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "")
      result = tool.execute.("call-1", %{}, nil, nil)

      assert %AgentToolResult{} = result
      assert is_list(result.content)
      assert length(result.content) >= 1

      text = hd(result.content).text
      assert is_binary(text)
    end

    test "returns result with non-existent session_id", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "nonexistent-session-id")
      result = tool.execute.("call-1", %{}, nil, nil)

      assert %AgentToolResult{} = result
      assert is_list(result.content)

      text = hd(result.content).text
      assert is_binary(text)
    end

    test "respects include_details parameter", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "")

      # Without details
      result_simple = tool.execute.("call-1", %{"include_details" => false}, nil, nil)
      # With details
      result_detailed = tool.execute.("call-2", %{"include_details" => true}, nil, nil)

      # Both should return valid results
      assert %AgentToolResult{} = result_simple
      assert %AgentToolResult{} = result_detailed
    end

    test "returns error when aborted" do
      tool = ExtensionsStatus.tool("/tmp", session_id: "test-session")

      # Create a signal and abort it
      signal = make_ref()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call-1", %{}, signal, nil)

      assert {:error, "Operation aborted"} = result
    end

    test "includes tool conflict info without session_id", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "")
      result = tool.execute.("call-1", %{}, nil, nil)

      assert %AgentToolResult{} = result
      # Details should include tool_conflicts computed from cwd
      assert Map.has_key?(result.details, :tool_conflicts)
      conflicts = result.details.tool_conflicts

      # Should have the standard conflict report structure
      assert is_map(conflicts)
      assert Map.has_key?(conflicts, :total_tools)
      assert Map.has_key?(conflicts, :builtin_count)
      assert Map.has_key?(conflicts, :extension_count)
      assert Map.has_key?(conflicts, :shadowed_count)
      assert Map.has_key?(conflicts, :conflicts)

      # Output should include Tool Registry section
      text = hd(result.content).text
      assert text =~ "Tool Registry"
    end

    test "includes tool conflict info with non-existent session_id", %{tmp_dir: tmp_dir} do
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "nonexistent-session-id")
      result = tool.execute.("call-1", %{}, nil, nil)

      assert %AgentToolResult{} = result
      # Details should include tool_conflicts computed from cwd
      assert Map.has_key?(result.details, :tool_conflicts)
      conflicts = result.details.tool_conflicts

      # Should have the standard conflict report structure
      assert is_map(conflicts)
      assert conflicts.total_tools > 0

      # Output should include Tool Registry section
      text = hd(result.content).text
      assert text =~ "Tool Registry"
    end
  end

  describe "integration with extensions" do
    test "shows loaded extensions", %{tmp_dir: tmp_dir} do
      # Create an extension
      ext_dir = Path.join(tmp_dir, "extensions")
      File.mkdir_p!(ext_dir)

      extension_code = """
      defmodule ExtStatusTestExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "ext-status-test"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def capabilities, do: [:tools]
      end
      """

      File.write!(Path.join(ext_dir, "ext_status_test.ex"), extension_code)

      # Load the extension
      {:ok, _extensions} = CodingAgent.Extensions.load_extensions([ext_dir])

      # Now check extensions_status
      tool = ExtensionsStatus.tool(tmp_dir, session_id: "")
      result = tool.execute.("call-1", %{}, nil, nil)

      assert %AgentToolResult{} = result
      text = hd(result.content).text

      # Should mention the extension
      assert text =~ "ext-status-test" or text =~ "ExtStatusTestExtension"

      # Cleanup
      :code.purge(ExtStatusTestExtension)
      :code.delete(ExtStatusTestExtension)
    end
  end
end
