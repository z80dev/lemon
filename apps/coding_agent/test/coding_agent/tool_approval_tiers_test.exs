defmodule CodingAgent.ToolApprovalTiersTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Extensions.ToolHooks
  alias CodingAgent.{ToolExecutor, ToolPolicy, ToolRegistry}
  alias CodingAgent.Tools.WebFetch
  alias LemonAgent.Types.AgentTool
  alias LemonCore.Config.Tools

  test "registry resolves approval against hook-rewritten LSP arguments" do
    parent = self()

    approval = fn request ->
      send(parent, {:approval, request})
      {:ok, :denied}
    end

    {:ok, tool} =
      ToolRegistry.get_tool("/tmp", "lsp",
        include_extensions: false,
        include_mcp: false,
        tool_policy: %{approval_mode: :write},
        approval_context: %{approval_request_fun: approval}
      )

    revised = %{
      "action" => "rename",
      "file" => "sample.ex",
      "new_name" => "renamed",
      "apply" => true
    }

    wrapped =
      ToolHooks.wrap_tool(tool, [on_tool_call: [fn _ -> {:replace_args, revised} end]], %{})

    result = wrapped.execute.("rewrite", %{"action" => "definition", "apply" => false}, nil, nil)
    assert result.is_error
    assert_received {:approval, request}
    assert request.action == ToolExecutor.project_action("lsp", revised)
    assert request.tool == "lsp"
  end

  @tag :tmp_dir
  test "write-mode gates write/edit/patch only when they would run project checkers", %{
    tmp_dir: dir
  } do
    parent = self()

    approval = fn request ->
      send(parent, {:approval, request.tool})
      {:ok, :denied}
    end

    File.write!(Path.join(dir, "a.txt"), "old\n")

    tool = fn name ->
      {:ok, tool} =
        ToolRegistry.get_tool(dir, name,
          include_extensions: false,
          include_mcp: false,
          tool_policy: %{approval_mode: :write},
          approval_context: %{approval_request_fun: approval}
        )

      tool
    end

    for flag <- ["diagnostics", "format"],
        {name, args} <- [
          {"write", %{"path" => "a.txt", "content" => "x\n"}},
          {"edit", %{"path" => "a.txt", "old_text" => "old", "new_text" => "new"}},
          {"patch", %{"patch_text" => "*** Begin Patch\n*** End Patch"}}
        ] do
      result = tool.(name).execute.("c-#{name}-#{flag}", Map.put(args, flag, true), nil, nil)
      assert result.is_error, "#{name} #{flag}"
      assert_received {:approval, ^name}
    end

    assert File.read!(Path.join(dir, "a.txt")) == "old\n"

    # Without a session journal the write stops at the intent gate, i.e. past approval.
    result = tool.("write").execute.("plain", %{"path" => "a.txt", "content" => "x\n"}, nil, nil)
    refute_received {:approval, _}
    assert result.details.reason == :intent_not_durable

    # A hook that adds the flag after the model's call is re-tiered too.
    hooked =
      ToolHooks.wrap_tool(
        tool.("write"),
        [
          on_tool_call: [
            fn _ ->
              {:replace_args, %{"path" => "a.txt", "content" => "y\n", "format" => true}}
            end
          ]
        ],
        %{}
      )

    assert hooked.execute.("hooked", %{"path" => "a.txt", "content" => "y\n"}, nil, nil).is_error
    assert_received {:approval, "write"}
  end

  @tag :tmp_dir
  test "trusted diagnostics/format defaults are tiered when the model omits them", %{
    tmp_dir: dir
  } do
    parent = self()

    approval = fn request ->
      send(parent, {:approval, request.tool})
      {:ok, :denied}
    end

    File.write!(Path.join(dir, "a.txt"), "old\n")

    tool = fn name, defaults ->
      {:ok, tool} =
        ToolRegistry.get_tool(
          dir,
          name,
          [
            include_extensions: false,
            include_mcp: false,
            tool_policy: %{approval_mode: :write},
            approval_context: %{approval_request_fun: approval}
          ] ++ defaults
        )

      tool
    end

    calls = [
      {"write", %{"path" => "a.txt", "content" => "x\n"}},
      {"edit", %{"path" => "a.txt", "old_text" => "old", "new_text" => "new"}},
      {"patch", %{"patch_text" => "*** Begin Patch\n*** End Patch"}}
    ]

    for defaults <- [[diagnostics: true], [format: true], [diagnostics: true, format: true]],
        {name, args} <- calls do
      assert tool.(name, defaults).execute.("d-#{name}", args, nil, nil).is_error
      assert_received {:approval, ^name}, "#{name} #{inspect(defaults)}"
    end

    # Explicit false overrides both defaults: no checker runs, no exec approval.
    for {name, args} <- calls do
      args = Map.merge(args, %{"diagnostics" => false, "format" => false})
      tool.(name, diagnostics: true, format: true).execute.("off-#{name}", args, nil, nil)
      refute_received {:approval, _}, name
    end
  end

  test "the gate re-resolves both directions after hooks revise arguments" do
    parent = self()

    tool = %AgentTool{
      name: "lsp",
      execute: fn _, args, _, _ ->
        send(parent, {:executed, args})
        :executed
      end
    }

    policy = ToolPolicy.parse!(%{approval_mode: :write})

    [{"lsp", wrapped, :builtin}] =
      ToolRegistry.gate_tuples([{"lsp", tool, :builtin}], policy, %{
        approval_request_fun: fn _ ->
          send(parent, :approval)
          {:ok, :denied}
        end
      })

    preview = %{"action" => "rename", "apply" => false}

    hooked =
      ToolHooks.wrap_tool(wrapped, [on_tool_call: [fn _ -> {:replace_args, preview} end]], %{})

    assert hooked.execute.("read", %{"action" => "rename", "apply" => true}, nil, nil) ==
             :executed

    assert_received {:executed, ^preview}
    refute_received :approval
  end

  test "canonical config seeds mode in registry while an explicit policy wins" do
    parent = self()
    config = %{tools: Tools.resolve(%{"tools" => %{"approval_mode" => "ask"}})}

    approval = fn _ ->
      send(parent, :asked)
      {:ok, :denied}
    end

    opts = [
      include_extensions: false,
      include_mcp: false,
      settings_manager: config,
      approval_context: %{approval_request_fun: approval}
    ]

    {:ok, tool} = ToolRegistry.get_tool("/tmp", "write", opts)

    assert tool.execute.("write", %{"path" => "never-created", "content" => "no"}, nil, nil).is_error

    assert_received :asked

    {:ok, read} =
      ToolRegistry.get_tool(
        "/tmp",
        "read",
        Keyword.put(opts, :tool_policy, %{approval_mode: :yolo})
      )

    assert {:error, _} =
             read.execute.("read", %{"path" => "/nonexistent-lemon-approval-test"}, nil, nil)

    refute_received :asked
  end

  test "canonical configured body cap reaches guarded fetch" do
    tools =
      Tools.resolve(%{
        "tools" => %{"web" => %{"fetch" => %{"max_body_bytes" => 3}}}
      })

    tool =
      WebFetch.tool("/tmp",
        settings_manager: %{tools: tools},
        cache_opts: %{"persistent" => false},
        fetch_send: fn request ->
          assert request.max_body_bytes == 3
          {:ok, %{status: 200, headers: [], body: "oversized"}}
        end
      )

    result = tool.execute.("bodycap", %{"url" => "https://8.8.8.8/configured-cap"}, nil, nil)
    assert inspect(result) =~ "body_too_large"
  end
end
