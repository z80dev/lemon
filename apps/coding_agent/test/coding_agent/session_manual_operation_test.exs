defmodule CodingAgent.SessionManualOperationTest do
  # Manual compaction and branch summaries call the model. They must run off the
  # session process so the session keeps answering while the provider is slow.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{AssistantMessage, TextContent}

  @registered_name :session_manual_operation_test
  @api :session_manual_operation_blocking

  # Blocks inside the provider until the test releases (or cancels) it.
  defmodule BlockingProvider do
    def stream(_model, _context, _opts) do
      send(:session_manual_operation_test, {:provider_called, self()})

      receive do
        {:release, text} ->
          response = %AssistantMessage{
            content: [%TextContent{text: text}],
            stop_reason: :stop
          }

          {:ok, stream} = LemonAi.EventStream.start_link()
          LemonAi.EventStream.complete(stream, response)
          {:ok, stream}

        :cancel ->
          {:error, :provider_cancelled}
      after
        5_000 -> {:error, :provider_timeout}
      end
    end
  end

  setup_all do
    LemonAi.ProviderRegistry.register(@api, BlockingProvider)
    on_exit(fn -> LemonAi.ProviderRegistry.unregister(@api) end)
  end

  setup do
    Process.register(self(), @registered_name)
    :ok
  end

  defp start_session(tmp_dir) do
    manager =
      Enum.reduce(1..6, SessionManager.new(tmp_dir), fn i, acc ->
        message =
          if rem(i, 2) == 1 do
            %{
              "role" => "user",
              "content" => String.duplicate("user#{i} ", 800),
              "timestamp" => i
            }
          else
            %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => String.duplicate("answer#{i} ", 800)}],
              "timestamp" => i
            }
          end

        SessionManager.append_message(acc, message)
      end)

    session_file = Path.join(tmp_dir, "session.jsonl")
    :ok = SessionManager.save_to_file(session_file, manager)

    opts = [
      cwd: tmp_dir,
      workspace_dir: Path.join(tmp_dir, "workspace"),
      tools: [],
      extension_inventory: {[], []},
      mcp_tools: [],
      session_file: session_file,
      model: Mocks.mock_model(api: @api),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    start_supervised!(Supervisor.child_spec({Session, opts}, restart: :temporary))
  end

  defp start_compact(session),
    do: Task.async(fn -> Session.compact(session, keep_recent_tokens: 1) end)

  defp start_summary(session), do: Task.async(fn -> Session.summarize_current_branch(session) end)

  # Waits until the provider is blocked inside the model call.
  defp await_provider do
    assert_receive {:provider_called, provider}, 5_000
    provider
  end

  defp task_pid(session), do: Session.get_state(session).manual_operation.task_pid

  defp assert_responsive(session) do
    assert %{session_id: _} = Session.get_stats(session)
    assert %{status: _} = Session.health_check(session)
    assert %{session_id: _} = Session.diagnostics(session)
  end

  describe "manual compaction" do
    test "abort during compaction replies :aborted promptly and the session stays responsive",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      caller = start_compact(session)
      provider = await_provider()

      assert_responsive(session)

      # Mutating calls that refuse to run during a stream refuse to race it too.
      assert {:error, :busy} = Session.compact(session)
      assert {:error, :busy} = Session.summarize_current_branch(session)
      assert {:error, :busy} = Session.navigate_tree(session, :root)
      assert {:error, :busy} = Session.plan(session, :enter)
      assert {:error, :already_streaming} = Session.prompt(session, "hello")
      assert {:error, :already_streaming} = Session.reload_extensions(session)

      task_ref = Process.monitor(task_pid(session))
      :ok = Session.abort(session)

      assert {:error, :aborted} = Task.await(caller, 2_000)
      assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 2_000
      assert Session.get_state(session).manual_operation == nil

      # The session is usable again afterwards.
      assert :ok = Session.prompt(session, "after abort")
      send(provider, :cancel)
    end

    test "completion applies the summary inside the session", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      Session.subscribe(session)
      caller = start_compact(session)
      provider = await_provider()

      assert_responsive(session)
      send(provider, {:release, "manual summary"})

      assert :ok = Task.await(caller, 5_000)

      assert_receive {:session_event, _, {:compaction_start, %{reason: :manual}}}
      assert_receive {:session_event, _, {:compaction_complete, %{summary: "manual summary"}}}

      state = Session.get_state(session)
      assert state.manual_operation == nil

      assert Enum.any?(
               SessionManager.entries(state.session_manager),
               &(&1.type == :compaction and &1.summary == "manual summary")
             )
    end

    test "a result for a session that moved on is discarded as stale", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      caller = start_compact(session)
      provider = await_provider()
      before = Session.get_state(session).session_manager

      :sys.replace_state(session, fn state -> %{state | turn_index: state.turn_index + 1} end)
      send(provider, {:release, "stale summary"})

      assert {:error, :stale_session} = Task.await(caller, 5_000)

      state = Session.get_state(session)
      assert state.manual_operation == nil
      assert SessionManager.entries(state.session_manager) == SessionManager.entries(before)
    end

    test "a crashed task replies with an error and clears the operation", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      caller = start_compact(session)
      provider = await_provider()

      Process.exit(task_pid(session), :kill)

      assert {:error, {:task_exit, :killed}} = Task.await(caller, 2_000)
      assert Session.get_state(session).manual_operation == nil
      assert_responsive(session)
      send(provider, :cancel)
    end

    test "a task past the timeout replies :timeout and is killed", %{tmp_dir: tmp_dir} do
      previous = Application.get_env(:coding_agent, CodingAgent.Session, [])

      Application.put_env(
        :coding_agent,
        CodingAgent.Session,
        Keyword.put(previous, :auto_compaction_task_timeout_ms, 200)
      )

      on_exit(fn -> Application.put_env(:coding_agent, CodingAgent.Session, previous) end)

      session = start_session(tmp_dir)
      caller = start_compact(session)
      provider = await_provider()
      task_ref = Process.monitor(task_pid(session))

      assert {:error, :timeout} = Task.await(caller, 5_000)
      assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 2_000
      assert Session.get_state(session).manual_operation == nil
      send(provider, :cancel)
    end

    test "terminating the session kills the task and answers the waiting caller",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)

      caller =
        Task.async(fn ->
          try do
            Session.compact(session, keep_recent_tokens: 1)
          catch
            :exit, reason -> {:exit, reason}
          end
        end)

      provider = await_provider()
      task_ref = Process.monitor(task_pid(session))

      :ok = GenServer.stop(session)

      assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 2_000

      case Task.await(caller, 2_000) do
        {:error, :session_terminated} -> :ok
        {:exit, _reason} -> :ok
      end

      send(provider, :cancel)
    end
  end

  describe "branch summary" do
    test "abort during a summary replies :aborted promptly and the session stays responsive",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      caller = start_summary(session)
      provider = await_provider()

      assert_responsive(session)
      assert {:error, :busy} = Session.compact(session)
      assert {:error, :busy} = Session.summarize_current_branch(session)
      assert {:error, :already_streaming} = Session.prompt(session, "hello")

      task_ref = Process.monitor(task_pid(session))
      :ok = Session.abort(session)

      assert {:error, :aborted} = Task.await(caller, 2_000)
      assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 2_000
      assert Session.get_state(session).manual_operation == nil
      send(provider, :cancel)
    end

    test "completion stores the branch summary and broadcasts it", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      Session.subscribe(session)
      caller = start_summary(session)
      provider = await_provider()

      assert_responsive(session)
      send(provider, {:release, "branch summary"})

      assert :ok = Task.await(caller, 5_000)
      assert_receive {:session_event, _, {:branch_summarized, %{summary: "branch summary"}}}

      state = Session.get_state(session)
      assert state.manual_operation == nil

      assert Enum.any?(
               SessionManager.entries(state.session_manager),
               &(&1.type == :branch_summary)
             )
    end

    test "an empty branch is rejected without starting a task", %{tmp_dir: tmp_dir} do
      session =
        start_supervised!(
          Supervisor.child_spec(
            {Session,
             [
               cwd: tmp_dir,
               workspace_dir: Path.join(tmp_dir, "workspace"),
               tools: [],
               extension_inventory: {[], []},
               mcp_tools: [],
               model: Mocks.mock_model(api: @api),
               stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
             ]},
            restart: :temporary
          )
        )

      assert {:error, :empty_branch} = Session.summarize_current_branch(session)
      assert Session.get_state(session).manual_operation == nil
      refute_receive {:provider_called, _}, 50
    end
  end
end
