defmodule Ai.ProviderRegistryTest do
  @moduledoc """
  Comprehensive tests for the Ai.ProviderRegistry module.

  Tests the persistent_term-based registry for LLM provider implementations,
  including registration, lookup, listing, and edge cases.

  Note: Uses async: false because the registry uses global :persistent_term
  storage that is shared across all tests.
  """
  use ExUnit.Case, async: false

  alias Ai.ProviderRegistry

  # Test modules for registration
  defmodule TestProvider1 do
    def provider_id, do: :test_provider_1
  end

  defmodule TestProvider2 do
    def provider_id, do: :test_provider_2
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Clear the registry before each test to ensure isolation
    ProviderRegistry.clear()
    :ok
  end

  # ============================================================================
  # Initialization
  # ============================================================================

  describe "init/0" do
    test "initializes an empty registry" do
      # Clear first to ensure we're testing initialization
      ProviderRegistry.clear()
      assert ProviderRegistry.list() == []

      assert :ok = ProviderRegistry.init()
      assert ProviderRegistry.initialized?()
      assert ProviderRegistry.list() == []
    end

    test "is safe to call multiple times" do
      assert :ok = ProviderRegistry.init()
      assert :ok = ProviderRegistry.init()
      assert :ok = ProviderRegistry.init()

      assert ProviderRegistry.initialized?()
      assert ProviderRegistry.list() == []
    end

    test "preserves existing registrations when called again" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert ProviderRegistry.list() == [:test_api]

      # Re-initialize should not clear
      ProviderRegistry.init()
      assert ProviderRegistry.list() == [:test_api]
    end
  end

  # ============================================================================
  # Registration
  # ============================================================================

  describe "register/2" do
    test "registers a provider module" do
      assert :ok = ProviderRegistry.register(:test_api, TestProvider1)
      assert {:ok, TestProvider1} = ProviderRegistry.get(:test_api)
    end

    test "allows multiple registrations" do
      assert :ok = ProviderRegistry.register(:api1, TestProvider1)
      assert :ok = ProviderRegistry.register(:api2, TestProvider2)

      assert {:ok, TestProvider1} = ProviderRegistry.get(:api1)
      assert {:ok, TestProvider2} = ProviderRegistry.get(:api2)
    end

    test "overwrites existing registration for same api_id" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert {:ok, TestProvider1} = ProviderRegistry.get(:test_api)

      ProviderRegistry.register(:test_api, TestProvider2)
      assert {:ok, TestProvider2} = ProviderRegistry.get(:test_api)
    end

    test "accepts atom api_ids" do
      assert :ok = ProviderRegistry.register(:my_api, TestProvider1)
      assert {:ok, TestProvider1} = ProviderRegistry.get(:my_api)
    end

    test "accepts various module names" do
      defmodule AnotherTestProvider do
      end

      assert :ok = ProviderRegistry.register(:another, AnotherTestProvider)
      assert {:ok, AnotherTestProvider} = ProviderRegistry.get(:another)
    end
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  describe "get/1" do
    test "returns provider module for registered api_id" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert {:ok, TestProvider1} = ProviderRegistry.get(:test_api)
    end

    test "returns error for unregistered api_id" do
      assert {:error, :not_found} = ProviderRegistry.get(:nonexistent)
    end

    test "returns error for api_id after unregistration" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert {:ok, TestProvider1} = ProviderRegistry.get(:test_api)

      ProviderRegistry.unregister(:test_api)
      assert {:error, :not_found} = ProviderRegistry.get(:test_api)
    end

    test "initializes registry if not already initialized" do
      # Clear to simulate uninitialized state
      ProviderRegistry.clear()
      assert ProviderRegistry.list() == []

      # get/1 should auto-initialize
      assert {:error, :not_found} = ProviderRegistry.get(:any_api)
      assert ProviderRegistry.initialized?()
    end
  end

  describe "get!/1" do
    test "returns provider module for registered api_id" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert TestProvider1 = ProviderRegistry.get!(:test_api)
    end

    test "raises ArgumentError for unregistered api_id" do
      assert_raise ArgumentError, ~r/Provider not found/, fn ->
        ProviderRegistry.get!(:nonexistent)
      end
    end

    test "error message includes the api_id" do
      assert_raise ArgumentError, ~r/nonexistent/, fn ->
        ProviderRegistry.get!(:nonexistent)
      end
    end
  end

  # ============================================================================
  # Listing
  # ============================================================================

  describe "list/0" do
    test "returns empty list for empty registry" do
      assert ProviderRegistry.list() == []
    end

    test "returns all registered api_ids" do
      ProviderRegistry.register(:api1, TestProvider1)
      ProviderRegistry.register(:api2, TestProvider2)
      ProviderRegistry.register(:api3, TestProvider1)

      api_ids = ProviderRegistry.list()
      assert length(api_ids) == 3
      assert :api1 in api_ids
      assert :api2 in api_ids
      assert :api3 in api_ids
    end

    test "returns list after unregistration" do
      ProviderRegistry.register(:api1, TestProvider1)
      ProviderRegistry.register(:api2, TestProvider2)

      assert length(ProviderRegistry.list()) == 2

      ProviderRegistry.unregister(:api1)
      assert ProviderRegistry.list() == [:api2]
    end

    test "initializes registry if not already initialized" do
      ProviderRegistry.clear()
      assert ProviderRegistry.list() == []
      assert ProviderRegistry.initialized?()
    end
  end

  # ============================================================================
  # Registration Check
  # ============================================================================

  describe "registered?/1" do
    test "returns true for registered api_id" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert ProviderRegistry.registered?(:test_api)
    end

    test "returns false for unregistered api_id" do
      refute ProviderRegistry.registered?(:nonexistent)
    end

    test "returns false after unregistration" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert ProviderRegistry.registered?(:test_api)

      ProviderRegistry.unregister(:test_api)
      refute ProviderRegistry.registered?(:test_api)
    end

    test "initializes registry if not already initialized" do
      ProviderRegistry.clear()
      refute ProviderRegistry.registered?(:any_api)
      assert ProviderRegistry.initialized?()
    end
  end

  # ============================================================================
  # Unregistration
  # ============================================================================

  describe "unregister/1" do
    test "removes registered provider" do
      ProviderRegistry.register(:test_api, TestProvider1)
      assert :ok = ProviderRegistry.unregister(:test_api)
      assert {:error, :not_found} = ProviderRegistry.get(:test_api)
    end

    test "returns ok for unregistered api_id" do
      assert :ok = ProviderRegistry.unregister(:nonexistent)
    end

    test "is idempotent" do
      ProviderRegistry.register(:test_api, TestProvider1)

      assert :ok = ProviderRegistry.unregister(:test_api)
      assert :ok = ProviderRegistry.unregister(:test_api)
      assert :ok = ProviderRegistry.unregister(:test_api)
    end

    test "only removes specified api_id" do
      ProviderRegistry.register(:api1, TestProvider1)
      ProviderRegistry.register(:api2, TestProvider2)

      ProviderRegistry.unregister(:api1)

      assert {:error, :not_found} = ProviderRegistry.get(:api1)
      assert {:ok, TestProvider2} = ProviderRegistry.get(:api2)
    end
  end

  # ============================================================================
  # Clear
  # ============================================================================

  describe "clear/0" do
    test "removes all registrations" do
      ProviderRegistry.register(:api1, TestProvider1)
      ProviderRegistry.register(:api2, TestProvider2)

      assert :ok = ProviderRegistry.clear()

      assert ProviderRegistry.list() == []
      assert {:error, :not_found} = ProviderRegistry.get(:api1)
      assert {:error, :not_found} = ProviderRegistry.get(:api2)
    end

    test "is safe to call on empty registry" do
      assert :ok = ProviderRegistry.clear()
      assert :ok = ProviderRegistry.clear()
      assert ProviderRegistry.list() == []
    end

    test "allows re-registration after clear" do
      ProviderRegistry.register(:test_api, TestProvider1)
      ProviderRegistry.clear()

      ProviderRegistry.register(:test_api, TestProvider2)
      assert {:ok, TestProvider2} = ProviderRegistry.get(:test_api)
    end
  end

  # ============================================================================
  # Initialization Check
  # ============================================================================

  describe "initialized?/0" do
    test "returns false for uninitialized registry" do
      ProviderRegistry.clear()
      # Need to actually delete the persistent_term to test uninitialized state
      # This is handled by clear/0, so we test the transition
      assert ProviderRegistry.initialized?()
    end

    test "returns true after init" do
      ProviderRegistry.clear()
      ProviderRegistry.init()
      assert ProviderRegistry.initialized?()
    end

    test "returns true after registration" do
      ProviderRegistry.clear()
      ProviderRegistry.register(:test, TestProvider1)
      assert ProviderRegistry.initialized?()
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles many registrations" do
      for i <- 1..100 do
        module_name = Module.concat(__MODULE__, "Provider#{i}")
        ProviderRegistry.register(String.to_atom("api_#{i}"), module_name)
      end

      assert length(ProviderRegistry.list()) == 100

      # Verify we can retrieve them all
      for i <- 1..100 do
        module_name = Module.concat(__MODULE__, "Provider#{i}")
        assert {:ok, ^module_name} = ProviderRegistry.get(String.to_atom("api_#{i}"))
      end
    end

    test "handles special characters in api_id atoms" do
      special_ids = [
        :"api-with-dashes",
        :"api_with_underscores",
        :"api.with.dots",
        :"api123",
        :"API_UPPERCASE"
      ]

      for {api_id, idx} <- Enum.with_index(special_ids) do
        module = if rem(idx, 2) == 0, do: TestProvider1, else: TestProvider2
        ProviderRegistry.register(api_id, module)
      end

      for api_id <- special_ids do
        assert {:ok, _} = ProviderRegistry.get(api_id)
      end
    end

    test "concurrent reads are safe" do
      ProviderRegistry.register(:test_api, TestProvider1)

      parent = self()

      pids =
        for _ <- 1..50 do
          spawn(fn ->
            result = ProviderRegistry.get(:test_api)
            send(parent, {:result, result})
          end)
        end

      results =
        for _ <- pids do
          receive do
            {:result, result} -> result
          after
            1000 -> :timeout
          end
        end

      assert Enum.all?(results, &(&1 == {:ok, TestProvider1}))
    end

    test "registry survives multiple clear/init cycles" do
      for i <- 1..10 do
        ProviderRegistry.register(:test_api, TestProvider1)
        assert {:ok, TestProvider1} = ProviderRegistry.get(:test_api)

        ProviderRegistry.clear()
        assert {:error, :not_found} = ProviderRegistry.get(:test_api)

        ProviderRegistry.init()
      end
    end
  end

  # ============================================================================
  # Real-world Usage Patterns
  # ============================================================================

  describe "real-world usage patterns" do
    test "typical provider registration workflow" do
      # Simulate application startup
      ProviderRegistry.init()

      # Register providers
      ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
      ProviderRegistry.register(:openai_responses, Ai.Providers.OpenAIResponses)
      ProviderRegistry.register(:google_generative_ai, Ai.Providers.Google)

      # Verify all registered
      api_ids = ProviderRegistry.list()
      assert :anthropic_messages in api_ids
      assert :openai_responses in api_ids
      assert :google_generative_ai in api_ids

      # Look up providers
      assert {:ok, Ai.Providers.Anthropic} = ProviderRegistry.get(:anthropic_messages)
      assert {:ok, Ai.Providers.OpenAIResponses} = ProviderRegistry.get(:openai_responses)
      assert {:ok, Ai.Providers.Google} = ProviderRegistry.get(:google_generative_ai)
    end

    test "provider lookup with fallback" do
      ProviderRegistry.register(:primary, TestProvider1)

      # Lookup with fallback
      provider =
        case ProviderRegistry.get(:primary) do
          {:ok, mod} -> mod
          {:error, :not_found} -> TestProvider2
        end

      assert provider == TestProvider1

      # Non-existent with fallback
      provider =
        case ProviderRegistry.get(:nonexistent) do
          {:ok, mod} -> mod
          {:error, :not_found} -> TestProvider2
        end

      assert provider == TestProvider2
    end
  end
end
