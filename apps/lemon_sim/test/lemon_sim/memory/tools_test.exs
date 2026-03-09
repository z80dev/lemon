defmodule LemonSim.Memory.ToolsTest do
  use ExUnit.Case, async: true

  alias LemonSim.Memory.Tools

  test "memory tools can write, read, patch, list, and delete files" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_mem_tools_#{System.unique_integer([:positive])}"
    root = Path.join(tmp_dir, namespace)

    tools = Tools.build(memory_root: tmp_dir, memory_namespace: namespace)

    write = find_tool!(tools, "memory_write_file")
    read = find_tool!(tools, "memory_read_file")
    patch = find_tool!(tools, "memory_patch_file")
    list = find_tool!(tools, "memory_list_files")
    delete = find_tool!(tools, "memory_delete_file")

    assert {:ok, _} =
             write.execute.(
               "w1",
               %{"path" => "notes/plan.md", "content" => "flank left"},
               nil,
               nil
             )

    assert File.read!(Path.join(root, "index.md")) =~ "# Memory Index"

    assert {:ok, read_result} = read.execute.("r1", %{"path" => "notes/plan.md"}, nil, nil)
    assert AgentCore.get_text(read_result) == "flank left"

    assert {:ok, patch_result} =
             patch.execute.(
               "p1",
               %{
                 "path" => "notes/plan.md",
                 "target" => "left",
                 "replacement" => "right",
                 "replace_all" => false
               },
               nil,
               nil
             )

    assert patch_result.details[:replacements] == 1

    assert {:ok, read_result_2} = read.execute.("r2", %{"path" => "notes/plan.md"}, nil, nil)
    assert AgentCore.get_text(read_result_2) == "flank right"

    assert {:ok, list_result} =
             list.execute.("l1", %{"path" => ".", "recursive" => true}, nil, nil)

    files = AgentCore.get_text(list_result)
    assert String.contains?(files, "index.md")
    assert String.contains?(files, "notes/plan.md")

    assert {:ok, _} = delete.execute.("d1", %{"path" => "notes/plan.md"}, nil, nil)

    assert {:error, "Memory file not found"} =
             read.execute.("r3", %{"path" => "notes/plan.md"}, nil, nil)
  end

  test "setup creates the memory root and default index file" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_mem_setup_#{System.unique_integer([:positive])}"
    root = Tools.setup!(memory_root: tmp_dir, memory_namespace: namespace)

    assert File.dir?(root)
    assert File.read!(Path.join(root, "index.md")) =~ "# Memory Index"
  end

  test "build does not mutate the filesystem" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_mem_build_#{System.unique_integer([:positive])}"
    root = Path.join(tmp_dir, namespace)

    _tools = Tools.build(memory_root: tmp_dir, memory_namespace: namespace)

    refute File.exists?(root)
  end

  test "memory tools reject path traversal" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_mem_safe_#{System.unique_integer([:positive])}"
    tools = Tools.build(memory_root: tmp_dir, memory_namespace: namespace)
    read = find_tool!(tools, "memory_read_file")

    assert {:error, "Path escapes memory root"} =
             read.execute.("r1", %{"path" => "../outside.md"}, nil, nil)
  end

  test "read tool bootstraps the workspace before reporting missing files" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_mem_read_bootstrap_#{System.unique_integer([:positive])}"
    root = Path.join(tmp_dir, namespace)
    tools = Tools.build(memory_root: tmp_dir, memory_namespace: namespace)
    read = find_tool!(tools, "memory_read_file")

    assert {:error, "Memory file not found"} =
             read.execute.("r1", %{"path" => "notes/missing.md"}, nil, nil)

    assert File.dir?(root)
    assert File.read!(Path.join(root, "index.md")) =~ "# Memory Index"
  end

  defp find_tool!(tools, name) do
    Enum.find(tools, fn tool -> tool.name == name end) ||
      raise "tool not found: #{name}"
  end
end
