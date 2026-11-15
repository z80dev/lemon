defmodule CodingAgent.VendorToolDialects603Test do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Planning
  alias CodingAgent.{SessionManager, ToolDialects, ToolRegistry}

  @moduletag :tmp_dir

  defp native(cwd, opts \\ []) do
    ToolRegistry.get_tools(
      cwd,
      Keyword.merge(
        [include_extensions: false, include_mcp: false, enabled_only: ~w(read edit bash patch)],
        opts
      )
    )
  end

  defp dialect(tools, family) do
    ToolDialects.apply(tools,
      vendor_tool_dialects: true,
      model: %{
        id: if(family == :claude, do: "claude-sonnet-4-6", else: "gpt-5.3-codex"),
        api: if(family == :claude, do: :anthropic_messages, else: :openai_codex_responses)
      }
    )
    |> Map.new(&{&1.name, &1})
  end

  test "defaults and unrelated models retain exactly the native tools", %{tmp_dir: cwd} do
    tools = native(cwd)
    assert ToolDialects.apply(tools, model: %{id: "claude-sonnet-4-6"}) == tools

    assert ToolDialects.apply(tools, vendor_tool_dialects: true, model: %{id: "gemini-3"}) ==
             tools

    assert LemonCore.Config.Tools.resolve(%{}).vendor_dialects == false

    assert LemonCore.Config.Tools.resolve(%{"tools" => %{"vendor_dialects" => true}}).vendor_dialects

    projected =
      ToolDialects.apply(tools,
        model: %{id: "claude-sonnet-4-6"},
        settings_manager: %{tools: %{vendor_dialects: true}}
      )

    invalid = LemonCore.Config.Tools.resolve(%{"tools" => %{"vendor_dialects" => "yes"}})

    assert Enum.any?(
             LemonCore.Config.Validator.validate_tools(invalid, []),
             &String.contains?(&1, "vendor_dialects")
           )

    assert Enum.any?(projected, &(&1.name == "Read"))
  end

  test "native denials cannot be bypassed through vendor names", %{tmp_dir: cwd} do
    tools = native(cwd, tool_policy: %{deny: ~w(read edit bash patch)})
    assert dialect(tools, :claude) == %{}
    assert dialect(tools, :codex) == %{}
  end

  test "vendor calls request the same native approval with translated arguments", %{tmp_dir: cwd} do
    parent = self()

    tools =
      native(cwd,
        # Native :ask mode exempts the :read tier; explicitly review this read.
        tool_policy: %{approval_mode: :ask, approvals: %{"read" => :always}},
        approval_context: %{
          approval_request_fun: fn request ->
            send(parent, {:approval, request})
            {:ok, :denied}
          end
        }
      )

    claude = dialect(tools, :claude)

    for {name, args, native_name, key} <- [
          {"Read", %{"file_path" => Path.join(cwd, "file.txt")}, "read", "path"},
          {"Edit", %{"file_path" => "file.txt", "old_string" => "a", "new_string" => "b"}, "edit",
           "path"},
          {"Bash", %{"command" => "touch never-created"}, "bash", "command"}
        ] do
      assert claude[name].execute.("denied", args, nil, nil).is_error
      assert_received {:approval, request}
      assert request.tool == native_name
      assert is_map(request.action)

      assert Map.has_key?(
               claude[name].parameters["properties"],
               if(key == "path", do: "file_path", else: key)
             )
    end

    patch = dialect(tools, :codex)["apply_patch"]
    text = "*** Begin Patch\n*** Add File: never-created\n+no\n*** End Patch\n"
    assert patch.execute.("denied", %{"input" => text}, nil, nil).is_error
    assert_received {:approval, %{tool: "patch"}}
    refute File.exists?(Path.join(cwd, "never-created"))

    assert patch.parameters["x-lemon-tool-format"]["definition"] =~
             "start: begin_patch hunk+ end_patch"
  end

  test "mapping preserves native edit ambiguity and mutation boundary", %{tmp_dir: cwd} do
    path = Path.join(cwd, "sample.txt")
    File.write!(path, "one one\n")
    tools = native(cwd)
    claude = dialect(tools, :claude)

    assert {:error, message} =
             claude["Edit"].execute.(
               "ambiguous",
               %{"file_path" => path, "old_string" => "one", "new_string" => "two"},
               nil,
               nil
             )

    assert message =~ "unique"
    assert File.read!(path) == "one one\n"

    result =
      claude["Edit"].execute.(
        "all",
        %{
          "file_path" => path,
          "old_string" => "one",
          "new_string" => "two",
          "replace_all" => true
        },
        nil,
        nil
      )

    refute result.is_error
    assert File.read!(path) == "two two\n"

    outside = Path.join(Path.dirname(cwd), "outside-#{Path.basename(cwd)}.txt")
    File.write!(outside, "untouched\n")
    on_exit(fn -> File.rm(outside) end)
    link = Path.join(cwd, "symlink.txt")
    File.ln_s!(outside, link)

    assert {:error, _} =
             claude["Edit"].execute.(
               "escape",
               %{"file_path" => link, "old_string" => "untouched", "new_string" => "changed"},
               nil,
               nil
             )

    assert File.read!(outside) == "untouched\n"
  end

  test "mapped read paging and Codex patch use the native implementations", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "sample.txt"), "first\nsecond\nthird\n")
    tools = native(cwd)
    read = dialect(tools, :claude)["Read"]

    result =
      read.execute.("read", %{"file_path" => "sample.txt", "offset" => 2, "limit" => 1}, nil, nil)

    assert Enum.any?(result.content, &(&1.text =~ "second"))
    text = "*** Begin Patch\n*** Add File: added.txt\n+hello\n*** End Patch\n"
    result = dialect(tools, :codex)["apply_patch"].execute.("patch", %{"input" => text}, nil, nil)
    refute result.is_error
    # Native patch strips the framing newline from an added file's content.
    assert File.read!(Path.join(cwd, "added.txt")) == "hello"
  end

  test "sandbox override is rejected rather than silently dropping a security option", %{
    tmp_dir: cwd
  } do
    bash = dialect(native(cwd), :claude)["Bash"]

    assert {:error, _} =
             bash.execute.(
               "override",
               %{"command" => "touch never-created", "dangerouslyDisableSandbox" => true},
               nil,
               nil
             )

    refute File.exists?(Path.join(cwd, "never-created"))
  end

  test "plan gates run on native names before dialect projection", %{tmp_dir: cwd} do
    manager = SessionManager.new(cwd)
    {:ok, _, manager} = Planning.transition(manager, :enter, [])

    context = %{
      gate: Planning.new_gate(),
      cwd: cwd,
      session_pid: self(),
      session_id: manager.header.id,
      run_id: "dialect-plan",
      session_key: nil,
      agent_id: "default",
      approval_request_fun: nil,
      dialect_opts: [vendor_tool_dialects: true, model: %{id: "claude-sonnet-4-6"}]
    }

    tools = Map.new(Planning.tools(native(cwd), manager, context), &{&1.name, &1})

    assert tools["Bash"].execute.("plan", %{"command" => "touch never-created"}, nil, nil).is_error

    assert tools["Edit"].execute.(
             "plan",
             %{"file_path" => "not-plan.txt", "old_string" => "a", "new_string" => "b"},
             nil,
             nil
           ).is_error

    refute File.exists?(Path.join(cwd, "never-created"))
  end

  test "registry exposes the opt-in dialect without bypassing native lookup policy", %{
    tmp_dir: cwd
  } do
    opts = [
      include_extensions: false,
      include_mcp: false,
      enabled_only: ["read"],
      vendor_tool_dialects: true,
      model: %{id: "claude-sonnet-4-6"}
    ]

    assert [%{name: "Read"}] = ToolRegistry.get_tools(cwd, opts)
    assert {:ok, %{name: "Read"}} = ToolRegistry.get_tool(cwd, "Read", opts)
    assert {:error, :not_found} = ToolRegistry.get_tool(cwd, "read", opts)

    assert {:error, :not_found} =
             ToolRegistry.get_tool(
               cwd,
               "Read",
               Keyword.put(opts, :tool_policy, %{deny: ["read"]})
             )
  end

  test "file operation extraction understands vendor calls without losing patch targets" do
    alias LemonAi.Types.{AssistantMessage, ToolCall}

    calls = [
      %ToolCall{name: "Read", arguments: %{"file_path" => "read.txt"}},
      %ToolCall{name: "Edit", arguments: %{"file_path" => "edited.txt"}},
      %ToolCall{
        name: "apply_patch",
        arguments: %{
          "input" =>
            "*** Begin Patch\n*** Update File: source.txt\n*** Move to: dest.txt\n@@\n-old\n+new\n*** End Patch\n"
        }
      }
    ]

    operations =
      CodingAgent.Compaction.extract_file_operations([%AssistantMessage{content: calls}])

    assert operations.read_files == ["read.txt"]
    assert Enum.sort(operations.modified_files) == ~w(dest.txt edited.txt source.txt)
  end

  test "translation retains cancellation and update callback identity" do
    parent = self()
    signal = make_ref()
    callback = fn _ -> :ok end

    native = %LemonAgent.Types.AgentTool{
      name: "edit",
      execute: fn id, params, received_signal, update ->
        send(parent, {:execution, id, params, received_signal, update})
        :unchanged_result
      end,
      on_stream: fn _ -> flunk("vendor calls cannot use native streaming preparation") end
    }

    edit = dialect([native], :claude)["Edit"]
    assert edit.on_stream == nil

    assert edit.execute.(
             "call",
             %{"file_path" => "target", "old_string" => "old", "new_string" => "new"},
             signal,
             callback
           ) == :unchanged_result

    assert_received {:execution, "call",
                     %{
                       "path" => "target",
                       "mode" => "text",
                       "old_text" => "old",
                       "new_text" => "new"
                     }, ^signal, ^callback}
  end

  test "upstream schema fields and embedded grammar match the reviewed manifest", %{tmp_dir: cwd} do
    manifest =
      :lemon_ai
      |> Application.app_dir("priv/upstream_identities.json")
      |> File.read!()
      |> Jason.decode!()

    tools = native(cwd)
    claude = dialect(tools, :claude)

    for name <- ~w(Read Edit Bash) do
      contract = manifest["tool_contracts"][name]

      assert Enum.sort(Map.keys(claude[name].parameters["properties"])) ==
               Enum.sort(contract["fields"])

      assert claude[name].parameters["required"] == contract["required"]
    end

    grammar =
      dialect(tools, :codex)["apply_patch"].parameters["x-lemon-tool-format"]["definition"]

    source = Enum.find(manifest["sources"], &(&1["id"] == "codex-tool-grammar"))
    pinned = Enum.find(source["files"], &String.ends_with?(&1["path"], ".lark"))
    assert Base.encode16(:crypto.hash(:sha256, grammar), case: :lower) == pinned["sha256"]
  end
end

defmodule CodingAgent.VendorToolDialects603StaleTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{FileReadTracker, ToolDialects, ToolRegistry}

  @moduletag :tmp_dir

  setup do
    if Process.whereis(FileReadTracker) == nil, do: start_supervised!(FileReadTracker)
    session_id = "dialect603-#{System.unique_integer([:positive])}"
    on_exit(fn -> FileReadTracker.forget_session(session_id) end)
    %{session_id: session_id}
  end

  test "mapped edit and apply_patch refuse changes made after the session read", %{
    tmp_dir: cwd,
    session_id: session_id
  } do
    path = Path.join(cwd, "stale.txt")
    File.write!(path, "seen\n")

    tools =
      ToolRegistry.get_tools(cwd,
        include_extensions: false,
        include_mcp: false,
        enabled_only: ~w(read edit patch),
        session_id: session_id,
        filesystem_checkpoints: false
      )

    claude =
      tools
      |> ToolDialects.apply(vendor_tool_dialects: true, model: %{id: "claude-sonnet-4-6"})
      |> Map.new(&{&1.name, &1})

    claude["Read"].execute.("read", %{"file_path" => path}, nil, nil)
    File.write!(path, "external change\n")

    assert {:error, error} =
             claude["Edit"].execute.(
               "edit",
               %{
                 "file_path" => path,
                 "old_string" => "external change",
                 "new_string" => "bad",
                 "replace_all" => true
               },
               nil,
               nil
             )

    assert error =~ "modified on disk since you last read"
    assert File.read!(path) == "external change\n"

    FileReadTracker.record([session_id: session_id], path, "seen\n")

    [patch] =
      tools
      |> Enum.filter(&(&1.name == "patch"))
      |> ToolDialects.apply(vendor_tool_dialects: true, model: %{id: "gpt-5.3-codex"})

    text =
      "*** Begin Patch\n*** Add File: not-created\n+no\n*** Update File: stale.txt\n@@\n-external change\n+bad\n*** End Patch\n"

    assert {:error, error} = patch.execute.("patch", %{"input" => text}, nil, nil)
    assert error =~ "modified on disk since you last read"
    refute File.exists?(Path.join(cwd, "not-created"))
    assert File.read!(path) == "external change\n"
  end
end
