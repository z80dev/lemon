defmodule LemonCore.SessionActivityTest do
  use ExUnit.Case, async: false

  alias LemonCore.{SessionActivity, Store}

  # The test Store's ETS backend, except that listing unresolved presence
  # pauses (inside the Store) until the test lets it continue.
  defmodule PausingBackend do
    alias LemonCore.Store.EtsBackend

    for {name, arity} <- EtsBackend.__info__(:functions), {name, arity} != {:list, 2} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: EtsBackend.unquote(name)(unquote_splicing(args))
    end

    def list(state, :session_activity_unresolved = table) do
      case :persistent_term.get({__MODULE__, :pause}, nil) do
        test when is_pid(test) ->
          :persistent_term.erase({__MODULE__, :pause})
          send(test, {:listing, self()})

          receive do
            :continue -> :ok
          end

        nil ->
          :ok
      end

      EtsBackend.list(state, table)
    end

    def list(state, table), do: EtsBackend.list(state, table)
  end

  test "a live-to-unresolved transition is never missed between a snapshot's reads" do
    key = "agent:default:activity-#{System.unique_integer([:positive])}"
    id = "invoke-#{System.unique_integer([:positive])}"
    test = self()

    owner =
      spawn(fn ->
        {:ok, ref} = SessionActivity.admit(key, %{kind: :node_invocation})
        send(test, {:admitted, self()})

        receive do
          :retire ->
            result = SessionActivity.retire_unresolved(ref, id, %{node_id: "n", node_pid: self()})
            send(test, {:retired, result})
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:admitted, ^owner}

    on_exit(fn ->
      :persistent_term.erase({PausingBackend, :pause})
      Store.delete(:session_activity_unresolved, id)
      Process.exit(owner, :kill)
    end)

    %{backend: LemonCore.Store.EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: PausingBackend})

    try do
      :persistent_term.put({PausingBackend, :pause}, test)
      snapshot = Task.async(fn -> SessionActivity.entries() end)
      assert_receive {:listing, store}, 2_000

      # The transition is attempted while the snapshot is between its reads.
      send(owner, :retire)
      Process.sleep(50)
      send(store, :continue)

      assert {:ok, entries} = Task.await(snapshot)
      assert [%{status: :active}] = Enum.filter(entries, &(&1.session_key == key))
      assert_receive {:retired, :ok}, 2_000
    after
      :sys.replace_state(Store, &%{&1 | backend: LemonCore.Store.EtsBackend})
    end

    assert {:ok, entries} = SessionActivity.entries()
    assert [%{status: :unknown}] = Enum.filter(entries, &(&1.session_key == key))
  end
end
