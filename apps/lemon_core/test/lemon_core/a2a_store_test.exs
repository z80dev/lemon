defmodule LemonCore.A2AStoreTest do
  use ExUnit.Case, async: true

  alias LemonCore.{A2AStore, Store}
  alias LemonCore.Store.EtsBackend

  defmodule TaskReadFailureBackend do
    @moduledoc false
    @behaviour LemonCore.Store.Backend

    @impl true
    defdelegate init(opts), to: EtsBackend
    @impl true
    defdelegate put(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate delete(state, table, key), to: EtsBackend

    @impl true
    def get(_state, :a2a_tasks, _key), do: {:error, :disk_read_failed}
    def get(state, table, key), do: EtsBackend.get(state, table, key)

    @impl true
    def list(_state, table) when table in [:a2a_tasks, :a2a_messages],
      do: {:error, :disk_read_failed}

    def list(state, table), do: EtsBackend.list(state, table)
  end

  setup do
    name = :"a2a_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
    %{store: name}
  end

  test "persists a default peer context and ordered history", %{store: store} do
    opts = [store: store]

    owner = {"default", "agent:default:main"}
    assert {:ok, context} = A2AStore.new_owned_context("hermes", owner, opts)
    assert A2AStore.default_context("hermes", owner, opts).id == context.id

    assert {:ok, _} =
             A2AStore.append_message(
               %{
                 id: "1",
                 peer_id: "hermes",
                 context_id: context.id,
                 role: "ROLE_USER",
                 text: "one"
               },
               opts
             )

    assert {:ok, _} =
             A2AStore.append_message(
               %{
                 id: "2",
                 peer_id: "hermes",
                 context_id: context.id,
                 role: "ROLE_AGENT",
                 text: "two"
               },
               opts
             )

    assert Enum.map(elem(A2AStore.history("hermes", context.id, opts), 1), & &1.text) == [
             "one",
             "two"
           ]

    assert {:ok, %{turn_count: 1}} =
             A2AStore.increment_turn(:outbound, "hermes", context.id, opts)
  end

  test "message replay returns the original durable record", %{store: store} do
    opts = [store: store]

    assert {:ok, original} =
             A2AStore.append_message(
               %{
                 id: "m1",
                 direction: :inbound,
                 peer_id: "hermes",
                 context_id: "c1",
                 task_id: "t1",
                 role: "ROLE_USER",
                 text: "one"
               },
               opts
             )

    assert {:ok, existing} =
             A2AStore.append_message(
               %{
                 id: "m1",
                 direction: :inbound,
                 peer_id: "hermes",
                 context_id: "c1",
                 task_id: "replacement-task",
                 role: "ROLE_USER",
                 text: "replacement"
               },
               opts
             )

    assert existing == original
    assert A2AStore.get_message("m1", opts) == original
  end

  test "scopes task inventory by authenticated peer", %{store: store} do
    opts = [store: store]

    :ok =
      A2AStore.put_task(
        %{id: "a", peer_id: "hermes", context_id: "c", direction: :inbound},
        opts
      )

    :ok =
      A2AStore.put_task(
        %{id: "b", peer_id: "other", context_id: "c", direction: :inbound},
        opts
      )

    assert {:ok, [%{id: "a"}]} = A2AStore.list_tasks("hermes", opts)
  end

  test "outbound contexts, defaults and tasks are visible only to their owner", %{store: store} do
    opts = [store: store]
    alice = {"alice", "agent:alice:main"}
    bob = {"bob", "agent:bob:main"}
    alice_other_session = {"alice", "agent:alice:other"}

    assert {:ok, context} = A2AStore.new_owned_context("hermes", alice, opts)
    assert A2AStore.owned_context("hermes", alice, context.id, opts).id == context.id

    for intruder <- [bob, alice_other_session] do
      assert A2AStore.default_context("hermes", intruder, opts) == nil
      assert A2AStore.owned_context("hermes", intruder, context.id, opts) == nil
    end

    assert A2AStore.owned_context("other-peer", alice, context.id, opts) == nil

    task = %{id: "t1", peer_id: "hermes", context_id: context.id, state: "TASK_STATE_WORKING"}
    assert :ok = A2AStore.put_owned_task(alice, task, opts)
    assert {:error, :foreign_task} = A2AStore.put_owned_task(bob, task, opts)
    assert %{state: "TASK_STATE_WORKING"} = A2AStore.owned_task("hermes", alice, "t1", opts)
    assert A2AStore.owned_task("hermes", bob, "t1", opts) == nil
    assert A2AStore.get_task("t1", opts) == nil

    assert :ok = A2AStore.put_owned_task(alice, %{task | state: "TASK_STATE_COMPLETED"}, opts)
    assert %{state: "TASK_STATE_COMPLETED"} = A2AStore.owned_task("hermes", alice, "t1", opts)

    legacy = %{id: "legacy", direction: :outbound, peer_id: "hermes", agent_id: "default"}
    :ok = Store.put(store, :a2a_contexts, {:outbound, "hermes", "legacy"}, legacy)

    assert A2AStore.owned_context("hermes", {"default", "agent:default:main"}, "legacy", opts) ==
             nil
  end

  test "the task table serves inbound records only", %{store: store} do
    opts = [store: store]
    legacy = %{id: "old", direction: :outbound, peer_id: "hermes", updated_at_ms: 1}
    :ok = Store.put(store, :a2a_tasks, "old", legacy)

    assert A2AStore.get_task("old", opts) == nil
    assert {:error, :not_found} = A2AStore.update_task("old", & &1, opts)
    assert {:ok, []} = A2AStore.list_tasks("hermes", opts)
    assert {:error, :invalid_task} = A2AStore.put_task(%{id: "x", direction: :outbound}, opts)

    :ok = A2AStore.put_task(%{id: "in", direction: :inbound, peer_id: "hermes"}, opts)

    assert {:ok, %{direction: :inbound}} =
             A2AStore.update_task("in", &Map.put(&1, :direction, :outbound), opts)

    assert {:ok, [%{id: "in"}]} = A2AStore.list_tasks("hermes", opts)
  end

  test "an unreadable task table is an error, never an unknown task or empty inventory" do
    store = :"a2a_store_failing_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, backend: TaskReadFailureBackend}, id: store)
    opts = [store: store]

    assert {:error, :store_unavailable} = A2AStore.fetch_task("t1", opts)
    assert {:error, :store_unavailable} = A2AStore.list_tasks("hermes", opts)
    assert {:error, :store_unavailable} = A2AStore.update_task("t1", & &1, opts)
    assert {:error, :store_unavailable} = A2AStore.history("hermes", "ctx", opts)
  end
end
