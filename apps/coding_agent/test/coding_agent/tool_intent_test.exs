defmodule CodingAgent.ToolIntentDurabilityTest do
  use ExUnit.Case, async: true

  alias CodingAgent.SessionManager
  alias CodingAgent.ToolIntent
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  defmodule FailingAppend do
    def write(_device, _data), do: {:error, :enospc}
    def datasync(_device), do: raise("must not sync a failed append")
  end

  defmodule FailingSync do
    def write(device, data), do: :file.write(device, data)
    def datasync(_device), do: {:error, :eio}
  end

  for {io, stage} <- [{FailingAppend, :append}, {FailingSync, :sync}],
      effect <- [:external, :idempotent] do
    @tag :tmp_dir
    test "#{stage} failure prevents #{effect} execution", %{tmp_dir: dir} do
      session = persisted_session(dir)
      parent = self()

      recorder = fn data ->
        case SessionManager.record_tool_intent(session, data, unquote(io)) do
          {:ok, _session} -> :ok
          {:error, reason, _session} -> {:error, reason}
        end
      end

      tool = ToolIntent.wrap(tool(parent, unquote(effect)), tool_intent_recorder: recorder)

      assert %AgentToolResult{is_error: true, details: %{outcome: :not_started}} =
               result = tool.execute.("call", %{}, nil, nil)

      refute_received :executed
      assert hd(result.content).text =~ "not run"
      SessionManager.close(session)
    end
  end

  @tag :tmp_dir
  test "none bypasses the recorder and keeps streaming", %{tmp_dir: _dir} do
    parent = self()
    original = %{tool(parent, :none) | on_stream: fn _event -> :ok end}

    wrapped =
      ToolIntent.wrap(original, tool_intent_recorder: fn _ -> flunk("unexpected sync") end)

    assert wrapped.on_stream == original.on_stream
    assert %AgentToolResult{} = wrapped.execute.("read", %{}, nil, nil)
    assert_received :executed
  end

  @tag :tmp_dir
  test "idempotent calls wait for the durable acknowledgement", %{tmp_dir: dir} do
    parent = self()
    session = persisted_session(dir)

    recorder = fn data ->
      assert data["effect"] == "idempotent"
      assert data["toolCallId"] == "call"
      assert data["tool"] == "probe"
      assert byte_size(data["argumentDigest"]) == 64
      assert {:ok, _session} = SessionManager.record_tool_intent(session, data)
      send(parent, :recorded)
      :ok
    end

    wrapped = ToolIntent.wrap(tool(parent, :idempotent), tool_intent_recorder: recorder)
    assert wrapped.on_stream == nil
    assert %AgentToolResult{} = wrapped.execute.("call", %{"secret" => "not journaled"}, nil, nil)
    assert_received :recorded
    assert_received :executed
    refute File.read!(session.file_path) =~ "not journaled"
    SessionManager.close(session)
  end

  test "missing recorder fails closed" do
    wrapped = ToolIntent.wrap(tool(self(), :external), [])

    assert %AgentToolResult{is_error: true, details: %{outcome: :not_started}} =
             wrapped.execute.("call", %{}, nil, nil)

    refute_received :executed
  end

  test "node receipt is bound to the exact call id" do
    marker = %{"recordedBy" => "controller", "toolCallId" => "call"}
    wrapped = ToolIntent.wrap(tool(self(), :external), controller_tool_intent: marker)
    assert %AgentToolResult{is_error: false} = wrapped.execute.("call", %{}, nil, nil)
    assert_received :executed
    assert %AgentToolResult{is_error: true} = wrapped.execute.("other", %{}, nil, nil)
    refute_received :executed
  end

  test "node nested effects require a live parent eval scope" do
    parent = self()
    marker = %{"recordedBy" => "controller", "toolCallId" => "eval"}
    nested = ToolIntent.wrap(tool(parent, :external), controller_parent_intent: marker)

    escaped =
      ToolIntent.with_parent_scope("eval", fn scope ->
        nested = ToolIntent.inherit_parent_scope(nested, scope)
        task = Task.async(fn -> nested.execute.("nested", %{}, nil, nil) end)
        assert %AgentToolResult{is_error: false} = Task.await(task)
        assert_received :executed
        nested
      end)

    assert %AgentToolResult{is_error: true} = escaped.execute.("late", %{}, nil, nil)
    assert %AgentToolResult{is_error: true} = nested.execute.("outside", %{}, nil, nil)
    refute_received :executed
  end

  test "builtins conservatively classify effectful families" do
    for name <-
          ~w(write edit patch bash eval debug ast_grep lsp lsp_diagnostics agent task browser_snapshot media_status remember kanban) do
      assert ToolIntent.builtin_effect(name) == :external
    end

    for name <- ~w(read ls grep find recall) do
      assert ToolIntent.builtin_effect(name) == :none
    end

    assert %AgentTool{}.effect == :external

    assert LemonAgent.new_tool(
             name: "test",
             description: "",
             effect: :idempotent,
             execute: fn _, _, _, _ -> %AgentToolResult{} end
           ).effect == :idempotent
  end

  @tag :tmp_dir
  test "latency hook measures the durable gate but none emits no intent timing", %{tmp_dir: dir} do
    parent = self()
    handler = make_ref()
    event = [:coding_agent, :tool_intent, :stop]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn event, measurements, metadata, target ->
          if self() == target, do: send(target, {event, measurements, metadata})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    session = persisted_session(dir)

    recorder = fn data ->
      {:ok, _session} = SessionManager.record_tool_intent(session, data)
      :ok
    end

    wrapped = ToolIntent.wrap(tool(parent, :external), tool_intent_recorder: recorder)
    wrapped.execute.("timed", %{}, nil, nil)
    assert_received {^event, %{duration_us: duration}, %{effect: :external, status: :ok}}
    assert is_integer(duration) and duration >= 0
    ToolIntent.wrap(tool(parent, :none), []).execute.("read", %{}, nil, nil)
    refute_received {^event, _, _}
    SessionManager.close(session)
  end

  @tag :tmp_dir
  test "registry MCP dispatch also refuses a failed durable intent", %{tmp_dir: dir} do
    {:ok, wrapped} =
      CodingAgent.ToolRegistry.get_tool(dir, "probe",
        include_extensions: false,
        mcp_tools: [tool(self(), :external)],
        tool_intent_recorder: fn _ -> {:error, :enospc} end
      )

    assert %AgentToolResult{is_error: true, details: %{outcome: :not_started}} =
             wrapped.execute.("mcp-call", %{}, nil, nil)

    refute_received :executed
  end

  defp persisted_session(dir) do
    SessionManager.new(dir)
    |> SessionManager.persist(Path.join(dir, "session.jsonl"))
  end

  defp tool(parent, effect) do
    %AgentTool{
      name: "probe",
      effect: effect,
      on_stream: fn _ -> send(parent, :streamed) end,
      execute: fn _, _, _, _ ->
        send(parent, :executed)
        %AgentToolResult{}
      end
    }
  end
end
