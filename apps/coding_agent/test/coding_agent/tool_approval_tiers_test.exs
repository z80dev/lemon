defmodule CodingAgent.ToolApprovalTiersTest do
  use ExUnit.Case, async: true
  alias CodingAgent.{ToolExecutor, ToolPolicy, ToolRegistry}
  alias CodingAgent.Extensions.ToolHooks
  alias LemonAgent.Types.AgentTool

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

  test "direct wrappers re-resolve both directions after hooks revise arguments" do
    parent = self()

    tool = %AgentTool{
      name: "lsp",
      execute: fn _, args, _, _ ->
        send(parent, {:executed, args})
        :executed
      end
    }

    policy = ToolPolicy.parse!(%{approval_mode: :write})

    wrapped =
      ToolExecutor.wrap_with_approval(tool, policy, %{
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
    config = %{tools: LemonCore.Config.Tools.resolve(%{"tools" => %{"approval_mode" => "ask"}})}

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

  test "WASM tools use exec tier and yolo disables capability defaults without bypassing overrides" do
    parent = self()
    fake = %AgentTool{name: "wasm_fixture", execute: fn _, _, _, _ -> :executed end}

    opts = [
      include_extensions: false,
      include_mcp: false,
      wasm_tools: [{fake.name, fake, {:wasm, %{capabilities: %{exec: true}}}}],
      approval_context: %{
        approval_request_fun: fn _ ->
          send(parent, :asked)
          {:ok, :denied}
        end
      }
    ]

    for mode <- [:ask, :write] do
      {:ok, tool} =
        ToolRegistry.get_tool(
          "/tmp",
          fake.name,
          Keyword.put(opts, :tool_policy, %{approval_mode: mode})
        )

      assert tool.execute.("wasm", %{}, nil, nil).is_error
      assert_received :asked
    end

    {:ok, tool} =
      ToolRegistry.get_tool(
        "/tmp",
        fake.name,
        Keyword.put(opts, :tool_policy, %{approval_mode: :yolo})
      )

    assert tool.execute.("wasm", %{}, nil, nil) == :executed
    refute_received :asked

    {:ok, tool} =
      ToolRegistry.get_tool(
        "/tmp",
        fake.name,
        Keyword.put(opts, :tool_policy, %{
          approval_mode: :yolo,
          approvals: %{fake.name => :always}
        })
      )

    assert tool.execute.("wasm", %{}, nil, nil).is_error
    assert_received :asked
  end

  test "canonical configured body cap reaches guarded fetch" do
    tools =
      LemonCore.Config.Tools.resolve(%{
        "tools" => %{"web" => %{"fetch" => %{"max_body_bytes" => 3}}}
      })

    tool =
      CodingAgent.Tools.WebFetch.tool("/tmp",
        settings_manager: %{tools: tools},
        cache_opts: %{"persistent" => false},
        http_get: fn _, _ -> {:ok, Req.Response.new(body: "oversized")} end
      )

    result = tool.execute.("bodycap", %{"url" => "https://8.8.8.8/configured-cap"}, nil, nil)
    assert inspect(result) =~ "body_too_large"
  end
end
