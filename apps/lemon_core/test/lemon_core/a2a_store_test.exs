defmodule LemonCore.A2AStoreTest do
  use ExUnit.Case, async: true

  alias LemonCore.{A2AStore, Store}

  setup do
    name = :"a2a_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
    %{store: name}
  end

  test "persists a default peer context and ordered history", %{store: store} do
    opts = [store: store]

    assert {:ok, context} =
             A2AStore.create_context(
               :outbound,
               "hermes",
               %{context_id: "friendship"},
               opts
             )

    assert :ok = A2AStore.set_default_context("hermes", context.id, opts)
    assert A2AStore.default_context("hermes", opts).id == "friendship"

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

    assert Enum.map(A2AStore.history("hermes", context.id, opts), & &1.text) == ["one", "two"]

    assert {:ok, %{turn_count: 1}} =
             A2AStore.increment_turn(:outbound, "hermes", context.id, opts)
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

    assert Enum.map(A2AStore.list_tasks("hermes", opts), & &1.id) == ["a"]
  end
end
