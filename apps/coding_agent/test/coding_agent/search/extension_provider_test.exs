defmodule CodingAgent.Search.ExtensionProviderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Extensions
  alias CodingAgent.Search.Registry

  defmodule Provider do
    @behaviour CodingAgent.Search.Provider
    def id, do: "extension-search"
    def capabilities, do: [:search, :extract]
    def available?(_capability, _context), do: :ok
    def search(request, _context), do: {:ok, %{"query" => request.query}}
    def extract(request, _context), do: {:ok, %{"url" => request.url}}
  end

  defmodule Extension do
    @behaviour CodingAgent.Extensions.Extension
    def name, do: "search-extension"
    def version, do: "1.0.0"
    def tools(_cwd), do: []
    def hooks, do: []
    def capabilities, do: [:search]
    def config_schema, do: %{}

    def providers do
      [
        %{
          type: :search,
          name: :extension_search,
          module: CodingAgent.Search.ExtensionProviderTest.Provider,
          config: %{priority: 75, endpoint: "redacted-by-provider"}
        }
      ]
    end
  end

  setup do
    Registry.reset()
    on_exit(&Registry.reset/0)
    :ok
  end

  test "extension lifecycle registers and unregisters search providers" do
    report = Extensions.register_extension_providers([Extension])

    assert report.total_registered == 1
    assert [%{type: :search, name: :extension_search, module: Provider}] = report.registered

    assert {:ok, spec} = Registry.fetch("extension_search")
    assert spec.capabilities == [:search, :extract]
    assert spec.priority == 75
    assert spec.source == "extension:search-extension"

    assert :ok = Extensions.unregister_extension_providers(report)
    assert {:error, :not_found} = Registry.fetch("extension_search")
  end

  test "bundled provider wins over an extension with the same name" do
    defmodule BraveShadowExtension do
      @behaviour CodingAgent.Extensions.Extension
      def name, do: "brave-shadow"
      def version, do: "1.0.0"

      def providers,
        do: [
          %{
            type: :search,
            name: :brave,
            module: CodingAgent.Search.ExtensionProviderTest.Provider
          }
        ]
    end

    report = Extensions.register_extension_providers([BraveShadowExtension])

    assert report.total_registered == 0
    assert {:ok, spec} = Registry.fetch("brave")
    assert spec.module == CodingAgent.Search.Providers.Brave
  end
end
