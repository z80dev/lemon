defmodule CodingAgent.SessionToolResourcesLifecycleTest do
  @moduledoc """
  Session-owned tool resources across finalize, abort and reset.

  A debug server holding only pending breakpoints is a real `ToolResources`
  resource that needs no adapter process. The abort test drives a real tool
  call blocked in a debug server backed by the fake DAP adapter (python3).
  """
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Debug.SessionServer
  alias CodingAgent.Session
  alias CodingAgent.Session.Presentation
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{Model, ModelCost}

  @moduletag :tmp_dir

  @fake_adapter Path.expand("../support/fake_dap_adapter.py", __DIR__)

  defp mock_model do
    %Model{
      id: "mock-model-1",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp start_session(tmp_dir, opts \\ []) do
    {:ok, session} =
      Session.start_link(Keyword.merge([cwd: tmp_dir, model: mock_model()], opts))

    session
  end

  defp session_id(session), do: Session.get_state(session).session_manager.header.id

  # Bind a debug server to `session` under `id`, as the debug tool does.
  defp bind_debug_resource(session, id, tmp_dir) do
    source = Path.join(tmp_dir, "main.c")
    File.write!(source, "int main;\n")

    assert {:ok, %{pending: true}} =
             SessionServer.call(id, %{action: "set_breakpoint", file: source, line: 1},
               owner: session,
               timeout_ms: 5_000
             )

    server = SessionServer.whereis(id)
    assert is_pid(server)
    on_exit(fn -> CodingAgent.ToolResources.stop(id) end)
    server
  end

  describe "finalize_session/2" do
    test "a failed save keeps the turn's tool resources from being preserved", %{
      tmp_dir: tmp_dir
    } do
      session = start_session(tmp_dir)
      id = session_id(session)
      server = bind_debug_resource(session, id, tmp_dir)
      ref = Process.monitor(server)

      # A non-empty directory at the session path makes the atomic save fail.
      path = Session.get_state(session).session_file
      File.rm!(path)
      File.mkdir_p!(Path.join(path, "blocker"))
      assert {:error, _reason} = Presentation.safe_save_session(session)

      Presentation.finalize_session(%{session: session, session_id: id}, true)

      refute Process.alive?(session)
      assert_receive {:DOWN, ^ref, :process, ^server, _reason}, 5_000
    end

    test "a successful save hands the resources off for the next turn", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      id = session_id(session)
      server = bind_debug_resource(session, id, tmp_dir)

      Presentation.finalize_session(%{session: session, session_id: id}, true)

      refute Process.alive?(session)
      assert Process.alive?(server)
      assert :sys.get_state(server).owner_pid == nil

      next_owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(next_owner, :stop) end)
      assert :ok = CodingAgent.ToolResources.bind(server, next_owner)
    end

    test "an uncertain handoff disposes resources already detached from their owner", %{
      tmp_dir: tmp_dir
    } do
      id = "uncertain-handoff-#{System.unique_integer([:positive])}"

      # Model a Session that saves and detaches resources, then dies before the
      # handoff reply reaches its executor. Detached resources no longer monitor it.
      session =
        spawn(fn ->
          receive do
            {:"$gen_call", from, :save} -> GenServer.reply(from, :ok)
          end

          receive do
            {:"$gen_call", _from, :handoff_tool_resources} ->
              :ok = CodingAgent.ToolResources.handoff(id, self())
          end
        end)

      on_exit(fn -> Process.exit(session, :kill) end)
      server = bind_debug_resource(session, id, tmp_dir)
      ref = Process.monitor(server)

      Presentation.finalize_session(%{session: session, session_id: id}, true)

      refute Process.alive?(session)
      assert_receive {:DOWN, ^ref, :process, ^server, _reason}, 5_000
    end
  end

  test "abort reaches a tool call blocked in a debug resource, then disposes the resource", %{
    tmp_dir: tmp_dir
  } do
    python = System.find_executable("python3")
    assert python, "python3 is required for the fake DAP adapter"

    continue =
      Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("debug", %{"action" => "continue", "timeout" => 60}, id: "debug-continue")
      ])

    session =
      start_session(tmp_dir,
        tool_disclosure: [enabled: false],
        stream_fn: Mocks.mock_stream_fn([continue])
      )

    id = session_id(session)
    log = Path.join(tmp_dir, "dap.jsonl")

    # A launched program that never stops again: `continue` blocks in the server.
    assert {:ok, %{state: :stopped}} =
             SessionServer.call(
               id,
               %{
                 action: "launch",
                 adapter: %{
                   name: "fake",
                   command: python,
                   args: [@fake_adapter, log],
                   connect_mode: :stdio,
                   launch_defaults: %{"stopOnEntry" => true, "fakeMode" => "hang"},
                   attach_defaults: %{}
                 },
                 program: Path.join(tmp_dir, "prog"),
                 cwd: tmp_dir,
                 args: [],
                 launch_overrides: %{}
               },
               owner: session,
               timeout_ms: 5_000
             )

    server = SessionServer.whereis(id)
    server_ref = Process.monitor(server)
    on_exit(fn -> CodingAgent.ToolResources.stop(id) end)

    _unsubscribe = Session.subscribe(session)
    :ok = Session.prompt(session, "keep the program running")

    assert_eventually(
      fn -> File.exists?(log) and File.read!(log) =~ ~s("request": "continue") end,
      timeout: 5_000
    )

    # Disposing the busy server waits for its 10 s shutdown timeout unless the
    # blocked call is cancelled first, so the run must observe the abort well
    # inside that window.
    :ok = Session.abort(session)
    assert_run_aborted(3_000)

    assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 15_000
  end

  defp assert_run_aborted(timeout_ms) do
    receive do
      {:session_event, _, {:tool_execution_end, "debug-continue", "debug", _result, _error}} ->
        :ok

      {:session_event, _, {:turn_end, %{stop_reason: :aborted}, _results}} ->
        :ok

      {:session_event, _, {:canceled, _reason}} ->
        :ok

      {:session_event, _, {:agent_end, _messages}} ->
        :ok
    after
      timeout_ms -> flunk("the run did not observe the abort within #{timeout_ms} ms")
    end
  end

  test "reset binds tools and resources to the fresh session id", %{tmp_dir: tmp_dir} do
    session = start_session(tmp_dir, tool_disclosure: [enabled: false])
    %{agent: agent, session_manager: %{header: %{id: old_id}}} = Session.get_state(session)

    source = Path.join(tmp_dir, "main.c")
    File.write!(source, "int main;\n")

    # Always run the debug tool the agent currently holds.
    set_breakpoint = fn ->
      tool = Enum.find(LemonAgent.Agent.get_state(agent).tools, &(&1.name == "debug"))

      tool.execute.(
        "bp",
        %{"action" => "set_breakpoint", "file" => source, "line" => 1},
        nil,
        nil
      )
    end

    refute set_breakpoint.().is_error
    old_server = SessionServer.whereis(old_id)
    assert is_pid(old_server)
    ref = Process.monitor(old_server)

    assert :ok = Session.reset(session)
    new_id = session_id(session)
    refute new_id == old_id
    on_exit(fn -> CodingAgent.ToolResources.stop(new_id) end)

    assert_receive {:DOWN, ^ref, :process, ^old_server, _reason}, 5_000

    refute set_breakpoint.().is_error
    new_server = SessionServer.whereis(new_id)
    assert is_pid(new_server)
    assert :sys.get_state(new_server).owner_pid == session
    assert_eventually(fn -> SessionServer.whereis(old_id) == nil end, timeout: 5_000)
  end
end
