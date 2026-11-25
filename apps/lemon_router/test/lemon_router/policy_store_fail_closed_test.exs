defmodule LemonRouter.PolicyStoreFailClosedTest do
  # Swaps the default Store's backend; other tests must not share it meanwhile.
  use ExUnit.Case, async: false

  alias LemonCore.{PolicyStore, ResumeToken, RunRequest, Store}
  alias LemonCore.Store.EtsBackend
  alias LemonRouter.{AgentDirectory, RunOrchestrator, SubmissionBuilder}

  # Wraps the test EtsBackend inside the real Store process and fails or stalls
  # reads of the tables selected through :persistent_term.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def set(faults), do: :persistent_term.put({__MODULE__, :faults}, faults)
    def clear, do: :persistent_term.erase({__MODULE__, :faults})
    defp fault(table), do: Map.get(:persistent_term.get({__MODULE__, :faults}, %{}), table)

    defdelegate init(opts), to: EtsBackend
    defdelegate put(state, table, key, value), to: EtsBackend
    defdelegate put_new(state, table, key, value), to: EtsBackend
    defdelegate delete(state, table, key), to: EtsBackend
    defdelegate sync(state), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend

    def get(state, table, key) do
      case fault(table) do
        :error ->
          {:error, :boom}

        {:stall, ms} ->
          Process.sleep(ms)
          EtsBackend.get(state, table, key)

        {:count, pid} ->
          send(pid, {:store_read, table, key})
          EtsBackend.get(state, table, key)

        nil ->
          EtsBackend.get(state, table, key)
      end
    end

    def list(state, table) do
      case fault(table) do
        nil -> EtsBackend.list(state, table)
        _ -> {:error, :boom}
      end
    end
  end

  defmodule CapturingRunProcess do
    use GenServer

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id] || System.unique_integer([:positive])},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      send(opts[:notify_pid], {:captured_job, opts[:execution_request]})
      {:ok, opts, {:continue, :stop}}
    end

    @impl true
    def handle_continue(:stop, state), do: {:stop, :normal, state}
  end

  setup do
    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    on_exit(fn ->
      FaultBackend.clear()
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
    end)

    session_key = "agent:default:main:failclosed-#{System.unique_integer([:positive])}"
    :ok = PolicyStore.put_session(session_key, %{tool_policy: %{deny: ["bash"]}})
    on_exit(fn -> Store.delete(:session_policies, session_key) end)

    run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    orchestrator =
      start_supervised!(
        {RunOrchestrator,
         name: nil,
         run_supervisor: run_supervisor,
         run_process_module: CapturingRunProcess,
         run_process_opts: %{notify_pid: self()}}
      )

    %{session_key: session_key, orchestrator: orchestrator}
  end

  test "baseline: the stored session policy denies bash for the admitted run", ctx do
    assert {:ok, _run_id} = RunOrchestrator.submit(ctx.orchestrator, request(ctx.session_key))
    assert_receive {:captured_job, job}
    refute LemonCore.ToolPolicy.allowed?(job.tool_policy, "bash")
  end

  for origin <- [:control_plane, :channel] do
    test "a failed session policy read rejects a #{origin} submission instead of running with full access",
         ctx do
      FaultBackend.set(%{session_policies: :error})

      assert RunOrchestrator.submit(ctx.orchestrator, request(ctx.session_key, unquote(origin))) ==
               {:error, :policy_unavailable}

      refute_receive {:captured_job, _job}, 200
    end
  end

  test "admission reads the session policy row exactly once per run", ctx do
    FaultBackend.set(%{session_policies: {:count, self()}})

    assert {:ok, submission} = SubmissionBuilder.build(request(ctx.session_key, :channel), %{})
    refute LemonCore.ToolPolicy.allowed?(submission.execution_request.tool_policy, "bash")

    session_key = ctx.session_key
    assert_received {:store_read, :session_policies, ^session_key}
    refute_received {:store_read, :session_policies, _key}
  end

  test "an unreadable chat default rejects a channel session's admission" do
    key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "test",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "#{System.unique_integer([:positive])}"
      })

    FaultBackend.set(%{chat_policies: :error})

    assert SubmissionBuilder.build(request(key, :channel), %{}) == {:error, :policy_unavailable}
  end

  @tag timeout: 30_000
  test "a Store call timeout on the session policy rejects admission", ctx do
    FaultBackend.set(%{session_policies: {:stall, 5_500}})

    assert SubmissionBuilder.build(request(ctx.session_key), %{}) ==
             {:error, :policy_unavailable}
  end

  test "an explicit resume token is never dropped when its binding cannot be read", ctx do
    FaultBackend.set(%{native_resume_contexts: :error})

    resume = %ResumeToken{engine: "lemon", value: "resume-#{System.unique_integer([:positive])}"}

    assert {:error, :resume_unavailable} =
             SubmissionBuilder.build(%{request(ctx.session_key) | resume: resume}, %{})
  end

  test "an unreadable persisted chat state rejects auto-resume instead of starting fresh",
       ctx do
    FaultBackend.set(%{chat: :error})

    # The chat table is mirrored in the read cache; a miss consults the store.
    assert {:error, :resume_unavailable} =
             SubmissionBuilder.build(request(ctx.session_key), %{})
  end

  test "the session directory surfaces an unreadable index instead of an empty list" do
    FaultBackend.set(%{sessions_index: :error})
    assert AgentDirectory.list_sessions() == {:error, :unavailable}
  end

  defp request(session_key, origin \\ :control_plane) do
    attrs = %{origin: origin, session_key: session_key, agent_id: "default", prompt: "hello"}

    attrs =
      if origin == :channel do
        Map.put(attrs, :meta, %{
          channel_context: %{channel_id: "test", peer_kind: :dm, peer_id: "1"},
          channel_identity: %{
            channel_id: "test",
            sender_id: "1",
            is_bot: false,
            owner?: false,
            verified?: true
          }
        })
      else
        attrs
      end

    RunRequest.new(Map.put(attrs, :run_id, LemonCore.Id.uuid()))
  end
end
