defmodule CodingAgent.StateStorageContractTest do
  use ExUnit.Case, async: false

  @lib_dir Path.expand("../../lib", __DIR__)
  @named_table_owners %{
    "coding_agent/file_read_tracker.ex" => CodingAgent.FileReadTracker,
    "coding_agent/parent_question_store_server.ex" => CodingAgent.ParentQuestionStoreServer,
    "coding_agent/process_store_server.ex" => CodingAgent.ProcessStoreServer,
    "coding_agent/run_graph_server.ex" => CodingAgent.RunGraphServer,
    "coding_agent/runtime_tables.ex" => CodingAgent.RuntimeTables,
    "coding_agent/task_progress_binding_server.ex" => CodingAgent.TaskProgressBindingServer,
    "coding_agent/task_store_server.ex" => CodingAgent.TaskStoreServer,
    "coding_agent/tools/todo_store_owner.ex" => CodingAgent.Tools.TodoStoreOwner,
    "coding_agent/workspace_reads.ex" => CodingAgent.WorkspaceReads
  }

  test "persistent_term writes are limited to explicit search-provider configuration" do
    sites =
      Enum.flat_map(sources(), fn {path, ast} ->
        {_ast, sites} =
          Macro.prewalk(ast, [], fn
            {kind, _, [head, body]} = node, sites when kind in [:def, :defp] ->
              if persistent_term_write?(body) do
                {node, [{path, function_name(head)} | sites]}
              else
                {node, sites}
              end

            node, sites ->
              {node, sites}
          end)

        sites
      end)

    assert Enum.sort(sites) == [
             {"coding_agent/search/registry.ex", :init},
             {"coding_agent/search/registry.ex", :register},
             {"coding_agent/search/registry.ex", :reset},
             {"coding_agent/search/registry.ex", :unregister}
           ]
  end

  test "all named ETS creation sites belong to application-supervised owners" do
    sites =
      Enum.flat_map(sources(), fn {path, ast} ->
        {_ast, sites} =
          Macro.prewalk(ast, [], fn
            {{:., _, [:ets, :new]}, _, [_name, opts]} = node, sites when is_list(opts) ->
              {node, if(:named_table in opts, do: [path | sites], else: sites)}

            {{:., _, [:ets, :new]}, _, _} = node, _sites ->
              flunk(
                "ETS options must be explicit for ownership review: #{path}: #{Macro.to_string(node)}"
              )

            node, sites ->
              {node, sites}
          end)

        sites
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert sites == Enum.sort(Map.keys(@named_table_owners))
    children = Supervisor.which_children(CodingAgent.Supervisor)

    for owner <- Map.values(@named_table_owners) do
      assert {^owner, pid, :worker, [^owner]} = List.keyfind(children, owner, 0)
      assert is_pid(pid)
    end
  end

  defp sources do
    @lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {Path.relative_to(path, @lib_dir), path |> File.read!() |> Code.string_to_quoted!()}
    end)
  end

  defp function_name({:when, _, [head | _]}), do: function_name(head)
  defp function_name({name, _, _}), do: name

  defp persistent_term_write?(ast) do
    {_ast, writes?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [:persistent_term, operation]}, _, _} = node, _writes?
        when operation in [:put, :erase] ->
          {node, true}

        node, writes? ->
          {node, writes?}
      end)

    writes?
  end
end
