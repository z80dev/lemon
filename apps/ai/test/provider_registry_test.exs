defmodule Ai.ProviderRegistryTest do
  # async: false because tests modify shared persistent_term state
  use ExUnit.Case, async: false

  alias Ai.ProviderRegistry

  # Generate a unique test ID for each test to avoid key collisions
  setup do
    test_id = System.unique_integer([:positive])
    {:ok, test_id: test_id}
  end

  describe "basic operations" do
    test "init/0 initializes the registry" do
      # init() is safe to call multiple times
      assert ProviderRegistry.init() == :ok
      assert ProviderRegistry.initialized?()
    end

    test "register/2 registers a provider", %{test_id: test_id} do
      api_id = :"test_api_#{test_id}"
      assert :ok = ProviderRegistry.register(api_id, TestProvider)
      assert {:ok, TestProvider} = ProviderRegistry.get(api_id)
    end

    test "get/1 returns error for unregistered provider", %{test_id: test_id} do
      api_id = :"nonexistent_#{test_id}"
      assert {:error, :not_found} = ProviderRegistry.get(api_id)
    end

    test "get!/1 raises for unregistered provider", %{test_id: test_id} do
      api_id = :"nonexistent_#{test_id}"

      assert_raise ArgumentError, ~r/Provider not found/, fn ->
        ProviderRegistry.get!(api_id)
      end
    end

    test "list/0 returns all registered API IDs", %{test_id: test_id} do
      api_a = :"api_a_#{test_id}"
      api_b = :"api_b_#{test_id}"
      ProviderRegistry.register(api_a, ModuleA)
      ProviderRegistry.register(api_b, ModuleB)

      ids = ProviderRegistry.list()
      assert api_a in ids
      assert api_b in ids
    end

    test "registered?/1 checks registration status", %{test_id: test_id} do
      api_id = :"test_api_#{test_id}"
      refute ProviderRegistry.registered?(api_id)
      ProviderRegistry.register(api_id, TestProvider)
      assert ProviderRegistry.registered?(api_id)
    end

    test "unregister/1 removes a provider", %{test_id: test_id} do
      api_id = :"test_api_#{test_id}"
      ProviderRegistry.register(api_id, TestProvider)
      assert ProviderRegistry.registered?(api_id)

      ProviderRegistry.unregister(api_id)
      refute ProviderRegistry.registered?(api_id)
    end
  end

  describe "crash resilience (persistent_term)" do
    test "registry survives multiple reads and writes", %{test_id: test_id} do
      # Register some providers with unique keys
      for i <- 1..10 do
        ProviderRegistry.register(:"api_#{test_id}_#{i}", Module.concat([TestProvider, "#{i}"]))
      end

      # Verify all are registered
      for i <- 1..10 do
        assert ProviderRegistry.registered?(:"api_#{test_id}_#{i}")
      end

      # List should have at least our 10
      ids = ProviderRegistry.list()
      registered_count = Enum.count(ids, &String.contains?(Atom.to_string(&1), "#{test_id}"))
      assert registered_count == 10
    end

    test "registry state persists across function calls", %{test_id: test_id} do
      # This simulates what would happen if the registry were a GenServer
      # and it crashed - with persistent_term, data survives
      api_id = :"persistent_test_#{test_id}"

      ProviderRegistry.register(api_id, PersistentModule)

      # In a different "process context" (simulated by calling from a task)
      task =
        Task.async(fn ->
          ProviderRegistry.get(api_id)
        end)

      assert {:ok, PersistentModule} = Task.await(task)
    end

    test "concurrent reads are safe", %{test_id: test_id} do
      # First, register all providers sequentially (writes have race conditions)
      for i <- 1..50 do
        api_id = :"concurrent_#{test_id}_#{i}"
        module = Module.concat([ConcurrentProvider, "#{test_id}", "#{i}"])
        ProviderRegistry.register(api_id, module)
      end

      # Then spawn many processes reading concurrently (reads are safe)
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            api_id = :"concurrent_#{test_id}_#{i}"
            expected_module = Module.concat([ConcurrentProvider, "#{test_id}", "#{i}"])

            result = ProviderRegistry.get(api_id)
            is_registered = ProviderRegistry.registered?(api_id)

            {result, is_registered, expected_module}
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed with correct values
      for {result, is_registered, expected_module} <- results do
        assert {:ok, ^expected_module} = result
        assert is_registered, "Expected registered? to return true"
      end
    end
  end

  describe "auto-initialization" do
    test "get/1 works after init", %{test_id: test_id} do
      # Ensure initialized (safe to call multiple times)
      ProviderRegistry.init()

      api_id = :"any_api_#{test_id}"

      # get should return not_found for unregistered api
      assert {:error, :not_found} = ProviderRegistry.get(api_id)

      # Registry should be initialized
      assert ProviderRegistry.initialized?()
    end
  end
end
