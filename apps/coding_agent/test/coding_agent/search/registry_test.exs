defmodule CodingAgent.Search.RegistryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Search.Registry

  defmodule SearchOnlyProvider do
    @behaviour CodingAgent.Search.Provider

    def id, do: "test-search"
    def capabilities, do: [:search]
    def available?(:search, _context), do: :ok
    def search(request, _context), do: {:ok, %{"query" => request.query}}
  end

  setup do
    Registry.reset()
    on_exit(&Registry.reset/0)
    :ok
  end

  test "lists bundled providers with capability metadata" do
    ids = Registry.list(capability: :search) |> Enum.map(& &1.id)

    assert "brave" in ids
    assert "perplexity" in ids
    assert "duckduckgo" in ids
    assert "searxng" in ids

    assert %{count: 6, search_count: 4, extract_count: 2} = Registry.status()
  end

  test "registers and unregisters a valid runtime provider" do
    assert :ok = Registry.register("test-search", SearchOnlyProvider, source: "extension:test")
    assert {:ok, spec} = Registry.fetch("TEST-SEARCH")
    assert spec.module == SearchOnlyProvider
    assert spec.capabilities == [:search]
    assert spec.source == "extension:test"

    assert {:error, :already_registered} = Registry.register("test-search", SearchOnlyProvider)
    assert :ok = Registry.unregister("test-search")
    assert {:error, :not_found} = Registry.fetch("test-search")
  end

  test "protects bundled providers and rejects invalid modules" do
    assert {:error, :builtin_provider} = Registry.unregister("brave")
    assert {:error, :invalid_provider} = Registry.register("bad", String)
  end
end
