defmodule LemonControlPlane.SessionLifecycleParticipantTest do
  use ExUnit.Case, async: false

  alias LemonCore.{
    Bus,
    ChatStateStore,
    ExecApprovals,
    ExecApprovalStore,
    PolicyStore,
    RunStore,
    SessionMetadataStore,
    Store
  }

  alias LemonControlPlane.SessionLifecycle

  alias LemonCore.SessionLifecycle.Participant
  alias LemonCore.TestSupport.SessionCleanup

  # Records every callback in an Agent and fails the step named by the test.
  defmodule Recorder do
    @behaviour LemonCore.SessionLifecycle.Participant

    def start(fail \\ nil) do
      {:ok, _} =
        Agent.start_link(fn -> %{fail: fail, calls: [], data: :present} end, name: __MODULE__)

      :ok
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def data, do: Agent.get(__MODULE__, & &1.data)

    defp step(name, result_fun) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: [name | state.calls]}
        if state.fail == name, do: {{:error, :injected}, state}, else: result_fun.(state)
      end)
    end

    @impl true
    def snapshot(_key, _op), do: step(:snapshot, &{{:ok, &1.data}, &1})

    @impl true
    def delete(_key, _op, _snapshot), do: step(:delete, &{:ok, %{&1 | data: nil}})

    @impl true
    def verify_deleted(_key, _op, _snapshot),
      do: step(:verify, &{if(&1.data == nil, do: :ok, else: {:error, :remains}), &1})

    @impl true
    def restore(_key, _op, snapshot), do: step(:restore, &{:ok, %{&1 | data: snapshot}})

    @impl true
    def commit(_key, _op, _snapshot), do: step(:commit, &{:ok, &1})
  end

  # EtsBackend that fails the next `list` or `delete` of one table.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend
    alias LemonCore.Store.EtsBackend

    def fail_next(op, table), do: :persistent_term.put({__MODULE__, op, table}, true)
    def clear(op, table), do: :persistent_term.erase({__MODULE__, op, table})

    defp fault?(op, table) do
      if :persistent_term.get({__MODULE__, op, table}, false) do
        clear(op, table)
        true
      end
    end

    def list(state, table),
      do: if(fault?(:list, table), do: {:error, :injected}, else: EtsBackend.list(state, table))

    def delete(state, table, key) do
      if fault?(:delete, table),
        do: {:error, :injected},
        else: EtsBackend.delete(state, table, key)
    end

    defdelegate init(opts), to: EtsBackend
    defdelegate get(state, table, key), to: EtsBackend
    defdelegate put(state, table, key, value), to: EtsBackend
    defdelegate put_new(state, table, key, value), to: EtsBackend
    defdelegate sync(state), to: EtsBackend
    defdelegate sweep(state, table, predicate), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend
  end

  setup do
    on_exit(fn -> Participant.unregister(:test_recorder) end)
    :ok
  end

  test "verified deletion covers every registered participant and commits after the canonical delete" do
    key = seeded("verified")
    :ok = Recorder.start()
    :ok = Participant.register(:test_recorder, Recorder)

    assert {:ok, %{verified: true}} = SessionCleanup.delete(key)
    assert Recorder.calls() == [:snapshot, :delete, :verify, :commit]
    assert Recorder.data() == nil
  end

  for step <- [:delete, :verify] do
    test "a participant whose #{step} fails returns an error and restores every store (#{step})" do
      key = seeded("participant_#{unquote(step)}")
      assert :ok = ChatStateStore.put(key, %{messages: ["keep"]})
      assert :ok = PolicyStore.put_session(key, %{model: "keep-model"})
      assert {:ok, _} = SessionLifecycle.patch(key, %{title: "Keep"})
      grant = seed_grant(key)
      :ok = Recorder.start(unquote(step))
      :ok = Participant.register(:test_recorder, Recorder)

      assert {:error, {:participant_delete_failed, :test_recorder}} = SessionCleanup.delete(key)

      assert :restore in Recorder.calls()
      refute :commit in Recorder.calls()
      assert Recorder.data() == :present
      assert SessionLifecycle.get(key)
      assert RunStore.history(key, limit: 1) != []
      assert ChatStateStore.get(key).messages == ["keep"]
      assert PolicyStore.fetch_session(key) == {:ok, %{model: "keep-model"}}
      assert SessionMetadataStore.get(key).title == "Keep"
      assert approved?(key, grant)
    end
  end

  test "an unreadable participant store stops deletion before any mutation" do
    key = seeded("snapshot_unavailable")
    assert :ok = ChatStateStore.put(key, %{messages: ["keep"]})
    :ok = Recorder.start(:snapshot)
    :ok = Participant.register(:test_recorder, Recorder)

    assert {:error, {:participant_unavailable, :test_recorder}} = SessionCleanup.delete(key)
    assert Recorder.calls() == [:snapshot]
    assert ChatStateStore.get(key).messages == ["keep"]
    assert SessionLifecycle.get(key)
  end

  test "an unavailable approval store makes delete fail and never report verified" do
    key = seeded("store_unavailable")
    assert :ok = ChatStateStore.put(key, %{messages: ["keep"]})

    result =
      with_backend(fn ->
        FaultBackend.fail_next(:list, :exec_approvals_policy_session)
        SessionCleanup.delete(key)
      end)

    assert {:error, {:participant_unavailable, :exec_approval_grants}} = result
    assert ChatStateStore.get(key).messages == ["keep"]
    assert SessionLifecycle.get(key)
  end

  test "delete and reset revoke session-scoped approval grants, including context grants" do
    deleted = seeded("grant_delete")
    reset = seeded("grant_reset")
    other = seeded("grant_other")

    grants = for key <- [deleted, reset, other], into: %{}, do: {key, seed_grant(key)}
    context_key = {:invocation_context, deleted, "ctx"}
    :ok = ExecApprovalStore.put_session_policy(context_key, "bash", "hash", %{approved: true})

    assert {:ok, %{verified: true}} = SessionCleanup.delete(deleted)
    assert {:ok, %{verified: true}} = SessionCleanup.reset(reset)

    refute approved?(deleted, grants[deleted])
    refute approved?(reset, grants[reset])
    assert approved?(other, grants[other])
    assert ExecApprovalStore.get_session_policy(context_key, "bash", "hash") == nil
  end

  test "a failing session-index delete returns an error and broadcasts no lifecycle event" do
    key = seeded("index_delete_fault")
    :ok = Bus.subscribe("sessions:lifecycle")

    result =
      with_backend(fn ->
        FaultBackend.fail_next(:delete, :sessions_index)
        RunStore.delete_session(key)
      end)

    assert {:error, _} = result
    refute_receive {:session_history_deleted, ^key, _}, 100
    refute_receive %{payload: {:session_history_deleted, ^key, _}}, 50
    assert RunStore.history(key, limit: 1) != []
    assert SessionLifecycle.get(key)
  end

  defp seeded(name) do
    key = "agent:participant_#{name}_#{System.unique_integer([:positive])}:main"
    run_id = "run-#{name}-#{System.unique_integer([:positive])}"

    :ok =
      RunStore.finalize(run_id, %{
        session_key: key,
        agent_id: key |> String.split(":") |> Enum.at(1),
        origin: :web,
        prompt: "prompt",
        completed: %{ok: true, answer: "answer"}
      })

    assert eventually(fn -> SessionLifecycle.get(key) != nil end)

    on_exit(fn ->
      Participant.unregister(:test_recorder)
      SessionCleanup.delete(key)
    end)

    key
  end

  defp seed_grant(key) do
    action = %{"command" => "echo #{key}"}
    hash = ExecApprovals.hash_action(action)

    :ok =
      ExecApprovalStore.put_session_policy(key, "bash", hash, %{approved: true, scope: :session})

    action
  end

  # A stored grant answers immediately; without one the request waits for its
  # (short) timeout.
  defp approved?(key, action) do
    case ExecApprovals.request(%{
           run_id: "run-check-#{System.unique_integer([:positive])}",
           session_key: key,
           tool: "bash",
           action: action,
           expires_in_ms: 50
         }) do
      {:ok, :approved, :session} -> true
      {:error, :timeout} -> false
    end
  end

  defp with_backend(fun) do
    %{backend: LemonCore.Store.EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    try do
      fun.()
    after
      FaultBackend.clear(:list, :exec_approvals_policy_session)
      FaultBackend.clear(:delete, :sessions_index)
      :sys.replace_state(Store, &%{&1 | backend: LemonCore.Store.EtsBackend})
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(), do: true, else: Process.sleep(10) && eventually(fun, attempts - 1)
  end
end
