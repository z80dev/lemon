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

  test "background writes retain parent approval namespace and remain gated", %{tmp_dir: tmp_dir} do
    parent =
      start_supervised!(
        {Session,
         [
           cwd: tmp_dir,
           model: Mocks.mock_model(),
           tools: [],
           agent_id: "background-writer",
           tool_policy:
             CodingAgent.ToolPolicy.custom(deny: ["bash"], require_approval: ["write"]),
           invocation_mcp_servers: [],
           invocation_context_key: "background-parent-client"
         ]}
      )

    owner = self()
    path = Path.join(tmp_dir, "background-denied.txt")

    runner = fn session_opts, _prompt, _signal, _timeout_ms ->
      send(owner, {:background_mcp_refs, Keyword.get(session_opts, :invocation_mcp_servers)})

      session_opts =
        Keyword.put(session_opts, :approval_context, %{
          approval_request_fun: fn request ->
            send(owner, {:background_approval, request})
            {:ok, :denied}
          end
        })

      {:ok, child} = Session.start_link(session_opts)

      try do
        write = Enum.find(Session.get_state(child).tools, &(&1.name == "write"))
        refute Enum.any?(Session.get_state(child).tools, &(&1.name == "bash"))

        result =
          write.execute.("background-write", %{"path" => path, "content" => "DENIED"}, nil, nil)

        send(owner, {:background_write_result, result})
        {:ok, "denied as required"}
      after
        GenServer.stop(child)
      end
    end

    assert {:ok, %{id: id}} =
             BackgroundRun.start("write in background",
               parent_session: parent,
               invocation_context_key: "replacement-client",
               invocation_mcp_servers: [%{"name" => "untrusted-widening"}],
               tool_policy: CodingAgent.ToolPolicy.from_profile(:full_access),
               runner: runner
             )

    assert_receive {:background_approval, request}, 2_000
    assert_receive {:background_mcp_refs, []}
    assert request.invocation_context_key == "background-parent-client"
    assert request.agent_id == "background-writer"
    assert request.run_id == id
    assert request.session_key == "background:#{id}"
    assert_receive {:background_write_result, %{is_error: true}}
    refute File.exists?(path)
    assert {:ok, "denied as required"} = await_result(id)
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

  test "scoped lifecycle hides foreign runs and permits their owning session" do
    owner_a = "agent:default:telegram:acct:dm:1"
    owner_b = "agent:default:telegram:acct:dm:2"
    test_pid = self()

    completed_runner = fn _session_opts, prompt, _signal, _timeout_ms -> {:ok, prompt} end

    assert {:ok, %{id: completed_id}} =
             BackgroundRun.start("owner A answer",
               session_key: owner_a,
               runner: completed_runner
             )

    assert {:ok, "owner A answer"} = await_result(completed_id)

    blocking_runner = fn _session_opts, _prompt, signal, _timeout_ms ->
      send(test_pid, :owner_b_started)
      wait_for_abort(signal)
      send(test_pid, :owner_b_aborted)
      {:error, :cancelled}
    end

    assert {:ok, %{id: running_id}} =
             BackgroundRun.start("owner B work", session_key: owner_b, runner: blocking_runner)

    assert_receive :owner_b_started, 1_000

    assert [%{id: ^completed_id}] = BackgroundRun.list_scoped(owner_a)
    assert [%{id: ^running_id}] = BackgroundRun.list_scoped(owner_b)
    assert [] = BackgroundRun.list_scoped(nil)

    assert {:ok, %{id: ^completed_id}} = BackgroundRun.status_scoped(completed_id, owner_a)
    assert {:ok, "owner A answer"} = BackgroundRun.result_scoped(completed_id, owner_a)

    for result <- [
          BackgroundRun.status_scoped(completed_id, owner_b),
          BackgroundRun.result_scoped(completed_id, owner_b),
          BackgroundRun.cancel_scoped(running_id, owner_a),
          BackgroundRun.status_scoped(completed_id, nil)
        ] do
      assert result == {:error, :not_found}
    end

    refute_received :owner_b_aborted
    assert :ok = BackgroundRun.cancel_scoped(running_id, owner_b)
    assert_receive :owner_b_aborted, 1_000
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

  test "side-query freezes source audience proof but cannot inherit shared writes" do
    owner = self()

    source = %{
      messages: transcript("authorized source", "authorized answer"),
      system_prompt: "safe",
      approval_context: %{
        invocation_context_key: "actor",
        memory_context_key: "audience",
        memory_context_verified: true,
        shared_memory_grant: true
      }
    }

    runner = fn opts, _question, _signal, _timeout ->
      send(owner, {:frozen_query_opts, opts})
      {:ok, "answer"}
    end

    assert {:ok, "answer"} = SideQuery.ask(source, "question", runner: runner)
    assert_receive {:frozen_query_opts, opts}
    assert opts[:invocation_context_key] == "actor"
    assert opts[:memory_context_key] == "audience"
    assert opts[:memory_context_verified] == true
    assert opts[:shared_memory_grant] == false
    assert opts[:tools] == []

    assert {:error, :session_unavailable} =
             SideQuery.ask(source, "question",
               runner: runner,
               invocation_context_key: "other-actor",
               memory_context_key: "audience",
               memory_context_verified: true
             )

    refute_receive {:frozen_query_opts, _}
  end

  test "side-query canonical negative source proof wins a forged string alias" do
    owner = self()

    source = %{
      messages: transcript("source", "answer"),
      system_prompt: "safe",
      approval_context: %{
        "memory_context_verified" => true,
        invocation_context_key: "actor",
        memory_context_key: "audience",
        memory_context_verified: false
      }
    }

    runner = fn opts, _, _, _ ->
      send(owner, {:negative_query_opts, opts})
      {:ok, "answer"}
    end

    assert {:ok, "answer"} = SideQuery.ask(source, "question", runner: runner)
    assert_receive {:negative_query_opts, opts}
    assert opts[:memory_context_verified] == false

    assert {:error, :session_unavailable} =
             SideQuery.ask(source, "question",
               runner: runner,
               invocation_context_key: "actor",
               memory_context_key: "audience",
               memory_context_verified: true
             )

    refute_receive {:negative_query_opts, _}
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

  defp await_result(id, attempts \\ 500)
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
