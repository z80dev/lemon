defmodule LemonSkills.Tools.RecallTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonMemory.{Document, Project, Store}
  alias LemonSkills.Tools.Recall

  @moduletag :tmp_dir

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  setup %{tmp_dir: tmp_dir} do
    store = :"recall_tool_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(tmp_dir, "store")})

    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    context = %{
      cwd: tmp_dir,
      workspace_dir: Path.join(tmp_dir, "home"),
      agent_id: "main",
      session_key: "agent:main:test:1",
      session_scope: :main
    }

    {:ok, scope} = Project.scope(context)

    for {agent, workspace, fact} <- [
          {"main", tmp_dir, "Priya's birthday is March 14th."},
          {"main", tmp_dir <> "-other", "Priya prefers wooden gifts."},
          {"other", tmp_dir <> "-other", "Priya's private unrelated note."}
        ] do
      Store.put_sync(
        store,
        Document.new(
          session_key: "agent:#{agent}:telegram:1",
          agent_id: agent,
          workspace_key: workspace,
          prompt_summary: "Priya birthday",
          answer_summary: fact,
          meta: %{"home_digest" => scope.home_digest}
        )
      )
    end

    %{
      store: store,
      context: context,
      search_fn: fn query, opts -> Store.search(store, query, opts) end
    }
  end

  test "browse and scroll expose only scoped session summaries", %{tmp_dir: dir, store: store} do
    tool = recall_tool(dir, agent_id: "main", store: store)
    browse = tool.execute.("browse", %{}, nil, nil)
    assert text(browse) =~ "agent:main:telegram:1"
    assert text(browse) =~ "2 runs"
    refute text(browse) =~ "agent:other"
    scroll = tool.execute.("scroll", %{"session" => "agent:main:telegram:1"}, nil, nil)
    assert text(scroll) =~ "March 14th"
    assert text(scroll) =~ "wooden gifts"
    assert text(scroll) =~ "Untrusted"
    refute text(scroll) =~ "private unrelated"

    assert text(tool.execute.("foreign", %{"session" => "agent:other:telegram:1"}, nil, nil)) =~
             "No matching"
  end

  test "agent scope recalls this agent across projects without another agent's facts", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = recall_tool(tmp_dir, session_key: "agent:main:telegram:1", search_fn: search_fn)
    result = tool.execute.("call", %{"query" => "Priya birthday"}, nil, nil)

    assert text(result) =~ "March 14th."
    assert text(result) =~ "wooden gifts."
    refute text(result) =~ "private unrelated"
  end

  test "project scope excludes facts from other projects", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = recall_tool(tmp_dir, agent_id: "main", search_fn: search_fn)
    result = tool.execute.("call", %{"query" => "Priya birthday", "scope" => "project"}, nil, nil)

    assert text(result) =~ "March 14th."
    refute text(result) =~ "wooden gifts."
    refute text(result) =~ "private unrelated"
  end

  test "also finds matching lines in memory notes, skipping the template", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    workspace_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(workspace_dir, "memory/topics"))

    File.write!(
      Path.join(workspace_dir, "memory/topics/deploys.md"),
      "# Ops notes\n\nStaging deploys need the VPN.\nUnrelated line.\n"
    )

    template = Path.join(workspace_dir, "memory/topics/TEMPLATE.md")
    File.write!(template, "staging deploy template\n")

    tool =
      recall_tool(tmp_dir,
        agent_id: "main",
        workspace_dir: workspace_dir,
        search_fn: search_fn
      )

    result = tool.execute.("call", %{"query" => "staging deploy"}, nil, nil)

    assert result.details.notes == 1
    assert text(result) =~ "memory/topics/deploys.md:3: Staging deploys need the VPN."
    refute text(result) =~ "TEMPLATE"
  end

  test "rejects an empty query, an unknown scope, and a missing agent", %{
    tmp_dir: tmp_dir,
    search_fn: search_fn
  } do
    tool = recall_tool(tmp_dir, agent_id: "main", search_fn: search_fn)

    assert {:error, "query must be a non-empty string"} =
             tool.execute.("call", %{"query" => "  "}, nil, nil)

    assert {:error, "scope must be agent or project"} =
             tool.execute.("call", %{"query" => "x", "scope" => "all"}, nil, nil)

    agentless = recall_tool(tmp_dir, search_fn: search_fn)

    assert {:error, message} = agentless.execute.("call", %{"query" => "x"}, nil, nil)
    assert message =~ "try scope project"
  end

  test "project history is shared with repository subdirectories", %{
    context: context,
    search_fn: search_fn
  } do
    nested = Path.join(context.cwd, "apps/example")
    File.mkdir_p!(nested)

    tool =
      recall_tool(nested,
        agent_id: context.agent_id,
        workspace_dir: context.workspace_dir,
        search_fn: search_fn
      )

    result = tool.execute.("call", %{"scope" => "project", "query" => "Priya birthday"}, nil, nil)
    assert text(result) =~ "March 14th"
    refute text(result) =~ "wooden gifts"
  end

  test "explicit project recall finds facts from repository subdirectories only", %{
    store: store,
    context: context,
    search_fn: search_fn
  } do
    fact = "Build release artifacts with mix release."
    assert {:ok, _} = Project.remember(context, fact, nil, store: store)
    nested = Path.join(context.cwd, "apps/example")
    File.mkdir_p!(nested)

    for {other, expected} <- [
          {%{context | cwd: nested}, 1},
          {%{context | cwd: context.cwd <> "-other"}, 0},
          {%{context | workspace_dir: context.workspace_dir <> "-other"}, 0},
          {%{context | agent_id: "other"}, 0}
        ] do
      opts = other |> Map.delete(:cwd) |> Map.to_list()
      tool = Recall.tool(other.cwd, opts ++ [store: store, search_fn: search_fn])

      result =
        tool.execute.("call", %{"scope" => "project", "query" => "release artifacts"}, nil, nil)

      assert result.details.project_facts == expected
      assert text(result) =~ fact == (expected == 1)
    end

    agent_tool = recall_tool(context.cwd, agent_id: "main", store: store, search_fn: search_fn)
    result = agent_tool.execute.("call", %{"query" => "release artifacts"}, nil, nil)
    assert result.details.project_facts == 0
    refute text(result) =~ fact
  end

  test "untrusted search results cannot cross profile, agent, or project boundaries", %{
    context: context
  } do
    {:ok, scope} = Project.scope(context)

    docs =
      for {agent, home, cwd, fact, kind} <- [
            {"main", scope.home_digest, context.cwd, "Allowed birthday history", nil},
            {"main", "foreign-home", context.cwd, "Foreign profile birthday history", nil},
            {"other", scope.home_digest, context.cwd, "Foreign agent birthday history", nil},
            {"main", nil, context.cwd, "Unscoped birthday history", nil},
            {"main", scope.home_digest, context.cwd <> "-other", "Other project birthday history",
             nil},
            {"main", scope.home_digest, context.cwd, "Project-only birthday fact",
             "project_learning"}
          ] do
        Document.new(
          agent_id: agent,
          session_key: "agent:#{agent}:test:1",
          workspace_key: cwd,
          prompt_summary: "birthday history",
          answer_summary: fact,
          meta: %{"home_digest" => home, "kind" => kind}
        )
      end

    for search_scope <- ["agent", "project"] do
      tool = recall_tool(context.cwd, agent_id: "main", search_fn: fn _, _ -> docs end)

      result =
        tool.execute.("call", %{"query" => "birthday history", "scope" => search_scope}, nil, nil)

      assert text(result) =~ "Allowed birthday history"
      refute text(result) =~ "Foreign profile"
      refute text(result) =~ "Foreign agent"
      refute text(result) =~ "Unscoped birthday"
      refute text(result) =~ "Project-only"
      assert text(result) =~ "Other project" == (search_scope == "agent")
    end
  end

  test "subagents and missing scope fail closed before searching", %{context: context} do
    for scope <- [:subagent, nil], search_scope <- ["agent", "project"] do
      tool =
        recall_tool(context.cwd,
          agent_id: "main",
          session_scope: scope,
          search_fn: fn _, _ -> flunk("unscoped recall must not search") end
        )

      assert {:error, _} =
               tool.execute.(
                 "call",
                 %{"query" => "birthday history", "scope" => search_scope},
                 nil,
                 nil
               )
    end
  end

  test "project recall does not surface agent-wide memory notes", %{
    context: context,
    search_fn: search_fn
  } do
    File.mkdir_p!(Path.join(context.workspace_dir, "memory"))
    File.write!(Path.join(context.workspace_dir, "memory/private.md"), "Private birthday plans")
    tool = recall_tool(context.cwd, agent_id: "main", search_fn: search_fn)

    result =
      tool.execute.("call", %{"query" => "private birthday", "scope" => "project"}, nil, nil)

    assert result.details.notes == 0
    refute text(result) =~ "Private birthday plans"
  end

  defp recall_tool(cwd, opts) do
    Recall.tool(
      cwd,
      Keyword.merge([workspace_dir: Path.join(cwd, "home"), session_scope: :main], opts)
    )
  end
end
