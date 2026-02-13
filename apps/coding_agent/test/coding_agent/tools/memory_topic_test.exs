defmodule CodingAgent.Tools.MemoryTopicTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.MemoryTopic

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with memory topic metadata" do
      tool = MemoryTopic.tool("/tmp", workspace_dir: "/tmp/ws")

      assert tool.name == "memory_topic"
      assert tool.label == "Create Memory Topic"
      assert tool.description =~ "memory/topics/<slug>.md"
      assert tool.parameters["required"] == ["topic"]
      assert tool.parameters["properties"]["topic"]["type"] == "string"
      assert tool.parameters["properties"]["overwrite"]["type"] == "boolean"
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/5" do
    test "creates a topic file from template", %{tmp_dir: tmp_dir} do
      workspace_dir = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(Path.join(workspace_dir, "memory/topics"))

      File.write!(
        Path.join(workspace_dir, "memory/topics/TEMPLATE.md"),
        "# Topic: <topic-slug>\n\ncustom-marker"
      )

      result =
        MemoryTopic.execute(
          "call_1",
          %{"topic" => "Solana RPC API"},
          nil,
          nil,
          workspace_dir
        )

      path = Path.join(workspace_dir, "memory/topics/solana-rpc-api.md")

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Created topic memory file"
      assert details.created == true
      assert details.overwritten == false
      assert details.slug == "solana-rpc-api"
      assert details.path == path
      assert File.read!(path) =~ "# Topic: solana-rpc-api"
      assert File.read!(path) =~ "custom-marker"
    end

    test "does not overwrite existing topic file by default", %{tmp_dir: tmp_dir} do
      workspace_dir = Path.join(tmp_dir, "workspace")
      topic_path = Path.join(workspace_dir, "memory/topics/rpc.md")

      File.mkdir_p!(Path.dirname(topic_path))
      File.write!(topic_path, "existing-content")

      result = MemoryTopic.execute("call_1", %{"topic" => "rpc"}, nil, nil, workspace_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "already exists"
      assert details.created == false
      assert details.overwritten == false
      assert File.read!(topic_path) == "existing-content"
    end

    test "overwrites existing topic file when overwrite=true", %{tmp_dir: tmp_dir} do
      workspace_dir = Path.join(tmp_dir, "workspace")
      template_path = Path.join(workspace_dir, "memory/topics/TEMPLATE.md")
      topic_path = Path.join(workspace_dir, "memory/topics/rpc.md")

      File.mkdir_p!(Path.dirname(topic_path))
      File.write!(template_path, "# Topic: <topic-slug>\n\nfresh")
      File.write!(topic_path, "stale-content")

      result =
        MemoryTopic.execute(
          "call_1",
          %{"topic" => "rpc", "overwrite" => true},
          nil,
          nil,
          workspace_dir
        )

      assert %AgentToolResult{details: details} = result
      assert details.created == true
      assert details.overwritten == true
      assert File.read!(topic_path) =~ "# Topic: rpc"
      refute File.read!(topic_path) =~ "stale-content"
    end

    test "returns error for invalid topic", %{tmp_dir: tmp_dir} do
      workspace_dir = Path.join(tmp_dir, "workspace")

      assert {:error, message} =
               MemoryTopic.execute("call_1", %{"topic" => "   "}, nil, nil, workspace_dir)

      assert message =~ "non-empty string"
    end
  end
end
