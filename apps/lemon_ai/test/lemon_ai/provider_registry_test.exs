defmodule LemonAi.ProviderRegistryTest do
  use ExUnit.Case, async: false

  alias LemonAi.ProviderRegistry
  alias LemonAi.Providers.{Anthropic, Google, OpenAIResponses}

  @registry_key {ProviderRegistry, :providers}

  setup do
    previous = :persistent_term.get(@registry_key, :absent)

    on_exit(fn ->
      case previous do
        :absent -> :persistent_term.erase(@registry_key)
        providers -> :persistent_term.put(@registry_key, providers)
      end
    end)

    :persistent_term.erase(@registry_key)
    :ok
  end

  test "reads leave an absent registry uninitialized" do
    refute ProviderRegistry.initialized?()
    assert_empty_registry()
    refute ProviderRegistry.initialized?()
  end

  test "init is repeatable and preserves configured providers" do
    assert :ok = ProviderRegistry.init()
    assert :ok = ProviderRegistry.init()
    assert ProviderRegistry.initialized?()
    assert_empty_registry()

    assert :ok = ProviderRegistry.register(:anthropic_messages, Anthropic)
    assert :ok = ProviderRegistry.init()
    assert ProviderRegistry.list() == [:anthropic_messages]
    assert {:ok, Anthropic} = ProviderRegistry.get(:anthropic_messages)
  end

  test "register initializes the registry, resolves providers and replaces a single API binding" do
    providers = [
      anthropic_messages: Anthropic,
      google_generative_ai: Google,
      openai_responses: OpenAIResponses
    ]

    for {api, module} <- providers do
      refute ProviderRegistry.registered?(api)
      assert :ok = ProviderRegistry.register(api, module)
      assert ProviderRegistry.registered?(api)
      assert {:ok, ^module} = ProviderRegistry.get(api)
      assert ^module = ProviderRegistry.get!(api)
    end

    assert ProviderRegistry.initialized?()
    assert Enum.sort(ProviderRegistry.list()) == Keyword.keys(providers)

    assert :ok = ProviderRegistry.register(:openai_responses, Anthropic)
    assert {:ok, Anthropic} = ProviderRegistry.get(:openai_responses)
    assert {:ok, Google} = ProviderRegistry.get(:google_generative_ai)
    assert Enum.sort(ProviderRegistry.list()) == Keyword.keys(providers)
  end

  test "unregister is idempotent and preserves other API bindings" do
    assert :ok = ProviderRegistry.register(:api1, Anthropic)
    assert :ok = ProviderRegistry.register(:api2, Google)

    for api <- [:missing, :api1, :api1] do
      assert :ok = ProviderRegistry.unregister(api)
      refute ProviderRegistry.registered?(api)
      assert {:error, :not_found} = ProviderRegistry.get(api)
      assert {:ok, Google} = ProviderRegistry.get(:api2)
    end

    assert ProviderRegistry.list() == [:api2]
  end

  test "clear leaves an initialized empty registry that accepts new registrations" do
    for module <- [Anthropic, Google] do
      assert :ok = ProviderRegistry.clear()
      assert :ok = ProviderRegistry.clear()
      assert ProviderRegistry.initialized?()
      assert_empty_registry()

      assert :ok = ProviderRegistry.init()
      assert :ok = ProviderRegistry.register(:missing, module)
      assert :ok = ProviderRegistry.register(:secondary, OpenAIResponses)
      assert {:ok, ^module} = ProviderRegistry.get(:missing)
    end
  end

  test "concurrent writes keep every registration visible to independent readers" do
    providers =
      for i <- 1..50 do
        api = :"concurrent_api_#{i}"
        module = if rem(i, 2) == 0, do: Anthropic, else: Google
        {api, module}
      end

    results =
      providers
      |> Enum.map(fn {api, module} ->
        Task.async(fn -> ProviderRegistry.register(api, module) end)
      end)
      |> Task.await_many(10_000)

    assert results == List.duplicate(:ok, length(providers))

    assert MapSet.new(ProviderRegistry.list()) == MapSet.new(Keyword.keys(providers))

    providers
    |> Enum.map(fn {api, module} ->
      Task.async(fn ->
        assert {:ok, ^module} = ProviderRegistry.get(api)
        assert ProviderRegistry.registered?(api)
      end)
    end)
    |> Task.await_many()
  end

  test "contended mutation raises instead of reporting a registration that never happened" do
    lock = {{ProviderRegistry, :mutation_lock}, self()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      contender =
        Task.async(fn ->
          assert_raise RuntimeError, "Provider registry lock unavailable", fn ->
            ProviderRegistry.register(:contended, Anthropic)
          end
        end)

      Task.await(contender, 10_000)
      assert ProviderRegistry.get(:contended) == {:error, :not_found}
    after
      :global.del_lock(lock, [node()])
    end

    assert :ok = ProviderRegistry.register(:contended, Anthropic)
    assert {:ok, Anthropic} = ProviderRegistry.get(:contended)
  end

  defp assert_empty_registry do
    assert ProviderRegistry.list() == []

    for api <- [:missing, :secondary] do
      assert {:error, :not_found} = ProviderRegistry.get(api)
      refute ProviderRegistry.registered?(api)

      assert_raise ArgumentError, "Provider not found for API: #{api}", fn ->
        ProviderRegistry.get!(api)
      end
    end
  end
end
