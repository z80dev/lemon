defmodule CodingAgent.BackgroundRunTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{BackgroundRun, Session, SideQuery, TaskStore}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{AssistantMessage, TextContent, UserMessage}

  setup do
    TaskStore.clear()

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "hermes-command-runs-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      TaskStore.clear()
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "background run uses a fresh full-tool session and leaves parent history untouched", %{
    tmp_dir: tmp_dir
  } do
    parent_messages = transcript("parent secret", "parent answer")

    {:ok, parent} =
      Session.start_link(
        cwd: tmp_dir,
        model: Mocks.mock_model(),
        tools: [],
        initial_messages: parent_messages
      )

    before_messages = Session.get_messages(parent)
    test_pid = self()

    stream_fn = fn model, context, options ->
      send(test_pid, {:background_context, context})

      Mocks.mock_stream_fn_single(Mocks.assistant_message("background done")).(
        model,
        context,
        options
      )
    end

    assert {:ok, %{id: id, status: :queued}} =
             BackgroundRun.start("inspect the workspace",
               parent_session: parent,
               session_key: "agent:default:telegram:acct:chat:1",
               stream_fn: stream_fn,
               timeout_ms: 2_000
             )

    assert_receive {:background_context, context}, 2_000
    assert context.tools != []
    assert Enum.any?(context.tools, &(&1.name == "read"))

    context_text = inspect(context.messages)
    assert context_text =~ "inspect the workspace"
    refute context_text =~ "parent secret"

    assert {:ok, "background done"} = await_result(id)
    assert Session.get_messages(parent) == before_messages

    assert {:ok, status} = BackgroundRun.status(id)
    assert status.status == :completed
    assert status.result_available
    assert [%{id: ^id}] = BackgroundRun.list()
  end

  test "background lifecycle cancellation is durable and signals the live worker" do
    test_pid = self()

    runner = fn session_opts, _prompt, signal, _timeout_ms ->
      send(test_pid, {:runner_started, session_opts})
      wait_for_abort(signal)
      send(test_pid, :runner_aborted)
      {:error, :cancelled}
    end

    assert {:ok, %{id: id}} =
             BackgroundRun.start("wait for cancellation", runner: runner, timeout_ms: 2_000)

    assert_receive {:runner_started, session_opts}, 1_000
    refute Keyword.has_key?(session_opts, :tools)

    private_reason = {:user_cancelled, "/Users/alice/private-cancel-reason"}
    assert :ok = BackgroundRun.cancel(id, private_reason)
    assert_receive :runner_aborted, 1_000
    assert {:error, :cancelled} = BackgroundRun.result(id)
    assert {:ok, %{status: :cancelled}} = BackgroundRun.status(id)
    assert {:error, :already_terminal} = BackgroundRun.cancel(id)

    assert {:ok, record, events} = TaskStore.get(id)
    assert record.error == private_reason
    refute inspect(events) =~ "/Users/alice"
  end

  test "side query freezes a live parent snapshot, has no tools, and does not append", %{
    tmp_dir: tmp_dir
  } do
    parent_messages = transcript("remember alpha", "alpha acknowledged")

    {:ok, parent} =
      Session.start_link(
        cwd: tmp_dir,
        model: Mocks.mock_model(),
        tools: [],
        initial_messages: parent_messages
      )

    before_messages = Session.get_messages(parent)
    test_pid = self()

    stream_fn = fn model, context, options ->
      send(test_pid, {:side_context, context})
      Mocks.mock_stream_fn_single(Mocks.assistant_message("alpha")).(model, context, options)
    end

    assert {:ok, "alpha"} =
             SideQuery.ask(parent, "what should I remember?",
               stream_fn: stream_fn,
               timeout_ms: 2_000
             )

    assert_receive {:side_context, context}, 1_000
    assert context.tools == []
    assert inspect(context.messages) =~ "remember alpha"
    assert inspect(context.messages) =~ "what should I remember?"
    assert Session.get_messages(parent) == before_messages
  end

  test "side query accepts a durable channel session key after the turn completed" do
    session_key = "agent:default:telegram:acct:chat:42"
    test_pid = self()

    history_fn = fn ^session_key, [limit: 20] ->
      [
        {"new", history_entry("second question", "second answer", 2)},
        {"old", history_entry("first question", "first answer", 1)}
      ]
    end

    runner = fn session_opts, question, _signal, timeout_ms ->
      send(test_pid, {:key_side_query, session_opts, question, timeout_ms})
      {:ok, "from history"}
    end

    assert {:ok, "from history"} =
             SideQuery.ask(session_key, "recall both turns",
               history_fn: history_fn,
               active_run_fn: fn ^session_key -> :none end,
               policy_fn: fn ^session_key ->
                 %{model: Mocks.mock_model(), thinking_level: "low"}
               end,
               runner: runner,
               timeout_ms: 1_234
             )

    assert_receive {:key_side_query, session_opts, "recall both turns", 1_234}
    assert Keyword.fetch!(session_opts, :tools) == []
    assert Keyword.fetch!(session_opts, :session_key) != session_key
    assert Keyword.fetch!(session_opts, :thinking_level) == :low

    assert Enum.map(Keyword.fetch!(session_opts, :initial_messages), &message_text/1) == [
             "first question",
             "first answer",
             "second question",
             "second answer"
           ]
  end

  test "key-based side query can use an active run summary before history indexing" do
    session_key = "agent:default:discord:acct:channel:7"
    test_pid = self()

    runner = fn session_opts, _question, _signal, _timeout_ms ->
      send(test_pid, {:active_side_query, session_opts})
      {:ok, "active context"}
    end

    assert {:ok, "active context"} =
             SideQuery.ask(session_key, "what is running?",
               history_fn: fn ^session_key, _opts -> [] end,
               active_run_fn: fn ^session_key -> {:ok, "run-active"} end,
               run_get_fn: fn "run-active" ->
                 %{
                   started_at: 10,
                   summary: %{
                     prompt: "active prompt",
                     completed: %{answer: "active answer"}
                   }
                 }
               end,
               runner: runner
             )

    assert_receive {:active_side_query, session_opts}

    assert Enum.map(Keyword.fetch!(session_opts, :initial_messages), &message_text/1) == [
             "active prompt",
             "active answer"
           ]
  end

  test "background public lifecycle redacts retained internal failure details" do
    private_reason =
      {:provider_failed, "/Users/alice/.secrets/private-provider.json",
       %{api_key: "sk-private-provider"}}

    runner = fn _session_opts, _prompt, _signal, _timeout_ms ->
      {:error, private_reason}
    end

    assert {:ok, %{id: id}} = BackgroundRun.start("fail privately", runner: runner)
    assert {:error, :failed} = await_result(id)
    assert {:ok, %{status: :error, error: :failed} = status} = BackgroundRun.status(id)

    public = inspect(status)
    refute public =~ "/Users/alice"
    refute public =~ "sk-private-provider"

    assert {:ok, record, events} = TaskStore.get(id)
    assert record.error == private_reason
    refute inspect(events) =~ "/Users/alice"
    refute inspect(events) =~ "sk-private-provider"
  end

  test "side-query public errors classify provider details without returning them" do
    private_reason =
      {:provider_failed, "/Users/alice/.secrets/private-provider.json",
       %{api_key: "sk-private-provider"}}

    runner = fn _session_opts, _question, _signal, _timeout_ms ->
      {:error, private_reason}
    end

    source = %{
      messages: transcript("remember alpha", "alpha acknowledged"),
      system_prompt: "safe"
    }

    assert {:error, :query_failed} = SideQuery.ask(source, "what?", runner: runner)
  end

  defp transcript(user_text, assistant_text) do
    [
      %UserMessage{role: :user, content: user_text, timestamp: 1},
      %AssistantMessage{
        role: :assistant,
        content: [%TextContent{type: :text, text: assistant_text}],
        stop_reason: :stop,
        timestamp: 2
      }
    ]
  end

  defp history_entry(prompt, answer, started_at) do
    %{
      started_at: started_at,
      summary: %{prompt: prompt, completed: %{answer: answer}}
    }
  end

  defp message_text(%UserMessage{content: text}), do: text
  defp message_text(%AssistantMessage{} = message), do: LemonAi.get_text(message)

  defp await_result(id, attempts \\ 100)
  defp await_result(id, 0), do: BackgroundRun.result(id)

  defp await_result(id, attempts) do
    case BackgroundRun.result(id) do
      {:error, :not_ready} ->
        Process.sleep(20)
        await_result(id, attempts - 1)

      result ->
        result
    end
  end

  defp wait_for_abort(signal) do
    if AbortSignal.aborted?(signal) do
      :ok
    else
      Process.sleep(10)
      wait_for_abort(signal)
    end
  end
end
