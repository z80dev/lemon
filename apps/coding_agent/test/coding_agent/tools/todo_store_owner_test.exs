defmodule CodingAgent.Tools.TodoStoreOwnerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{TodoStore, TodoStoreOwner}

  @table :coding_agent_todo_store_owner_test
  @owner __MODULE__.Owner

  setup do
    owner = start_supervised!({TodoStoreOwner, name: @owner, table: @table})
    %{owner: owner}
  end

  test "the supervised process owns its named public set", %{owner: owner} do
    assert Process.whereis(@owner) == owner
    assert :ets.info(@table, :owner) == owner
    assert :ets.info(@table, :named_table)
    assert :ets.info(@table, :protection) == :public
    assert :ets.info(@table, :type) == :set
    assert :ets.info(@table, :read_concurrency)
    assert :ets.info(@table, :write_concurrency)

    assert {:error, {:already_started, ^owner}} =
             TodoStoreOwner.start_link(name: @owner, table: @table)
  end

  test "the table outlives a monitored client", %{owner: owner} do
    {client, ref} =
      spawn_monitor(fn -> :ets.insert(@table, {"session", [%{content: "retained"}]}) end)

    assert_receive {:DOWN, ^ref, :process, ^client, :normal}
    assert :ets.lookup(@table, "session") == [{"session", [%{content: "retained"}]}]
    assert :ets.info(@table, :owner) == owner
  end

  test "restart recreates the disposable projection under the new owner", %{owner: owner} do
    :ets.insert(@table, {"session", []})
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    ref = Process.monitor(owner)

    assert :ok = Supervisor.terminate_child(supervisor, TodoStoreOwner)
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}
    assert :ets.whereis(@table) == :undefined
    assert {:ok, restarted} = Supervisor.restart_child(supervisor, TodoStoreOwner)
    assert :ets.info(@table, :owner) == restarted
    assert :ets.lookup(@table, "session") == []
  end

  test "the public store writes to the application owner, never to a client" do
    session_id = "todo-owner-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(:coding_agent_todos, session_id) end)

    {client, ref} =
      spawn_monitor(fn -> TodoStore.put(session_id, [%{content: "retained"}]) end)

    assert_receive {:DOWN, ^ref, :process, ^client, :normal}
    assert TodoStore.get(session_id) == [%{content: "retained"}]
    assert :ets.info(:coding_agent_todos, :owner) == Process.whereis(TodoStoreOwner)
  end
end
