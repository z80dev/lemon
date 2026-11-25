defmodule LemonCore.PolicyStoreFailClosedTest do
  # Swaps the default Store's backend, so it cannot share the store with other
  # tests running concurrently.
  use ExUnit.Case, async: false

  alias LemonCore.{PolicyStore, Store}
  alias LemonCore.Store.EtsBackend

  # Wraps the test EtsBackend and fails or stalls reads of the policy tables
  # selected through :persistent_term, inside the real Store process.
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

    def get(state, table, key) do
      case fault(table) do
        :error ->
          {:error, :boom}

        {:stall, ms} ->
          Process.sleep(ms)
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

  @policy_tables [:session_policies]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    on_exit(fn ->
      FaultBackend.clear()
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
    end)

    id = "fail-closed-#{System.unique_integer([:positive])}"
    :ok = PolicyStore.put_session(id, %{tool_policy: %{deny: ["bash"]}})

    on_exit(fn ->
      FaultBackend.clear()
      Store.delete(:session_policies, id)
    end)

    %{id: id}
  end

  test "strict reads distinguish a confirmed absent policy from a stored one", %{id: id} do
    assert {:ok, %{tool_policy: %{deny: ["bash"]}}} = PolicyStore.fetch_session(id)
    assert {:ok, nil} = PolicyStore.fetch_session(id <> "-absent")
  end

  test "a backend error is store_unavailable, never an absent policy", %{id: id} do
    FaultBackend.set(Map.new(@policy_tables, &{&1, :error}))

    assert PolicyStore.fetch_session(id) == {:error, :store_unavailable}
  end

  @tag timeout: 30_000
  test "a Store call timeout is store_unavailable, never an absent policy", %{id: id} do
    FaultBackend.set(%{session_policies: {:stall, 5_500}})

    assert PolicyStore.fetch_session(id) == {:error, :store_unavailable}
  end

  test "session deletion never discards a policy whose snapshot could not be read", %{id: id} do
    FaultBackend.set(%{session_policies: :error})

    assert {:error, _reason} =
             LemonCore.TestSupport.SessionCleanup.delete(id,
               canonical_verify_fun: fn _key -> {:error, :forced_verification_failure} end
             )

    FaultBackend.clear()
    assert {:ok, %{tool_policy: %{deny: ["bash"]}}} = Store.fetch(:session_policies, id)
  end

  test "the lenient readers are gone, so no caller can collapse a failure into nil" do
    Code.ensure_loaded!(PolicyStore)

    for fun <- [:get_session] do
      refute function_exported?(PolicyStore, fun, 1),
             "PolicyStore.#{fun} still collapses read failures into an absent policy"
    end
  end
end
