defmodule LemonGateway.TransportRegistryTest do
  use ExUnit.Case, async: false

  alias LemonGateway.TransportRegistry

  defmodule MockTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "mock"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule AnotherTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "another"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule ThirdTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "third-transport"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule UnderscoreTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "my_transport"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule NumericTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "transport123"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule InvalidIdTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "Invalid-ID"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule NumericStartTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "123transport"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule SpaceTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "my transport"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule EmptyIdTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: ""

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule SpecialCharsTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "trans@port!"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule ReservedIdTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "default"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule ReservedAllTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "all"

    @impl true
    def start_link(_opts), do: :ignore
  end

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
    Application.put_env(:lemon_gateway, :commands, [])

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, :transports)
    end)

    :ok
  end

  test "lists registered transports" do
    Application.put_env(:lemon_gateway, :transports, [MockTransport, AnotherTransport])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    ids = TransportRegistry.list_transports()
    assert "mock" in ids
    assert "another" in ids
  end

  test "get_transport returns module for valid id" do
    Application.put_env(:lemon_gateway, :transports, [MockTransport])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert TransportRegistry.get_transport("mock") == MockTransport
  end

  test "get_transport returns nil for unknown id" do
    Application.put_env(:lemon_gateway, :transports, [MockTransport])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert TransportRegistry.get_transport("unknown") == nil
  end

  test "get_transport! raises for unknown id" do
    Application.put_env(:lemon_gateway, :transports, [MockTransport])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert catch_exit(TransportRegistry.get_transport!("unknown"))
  end

  test "rejects invalid transport id format" do
    Application.put_env(:lemon_gateway, :transports, [InvalidIdTransport])

    # The error happens during registry init which fails app start
    assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
  end

  test "rejects reserved transport id" do
    Application.put_env(:lemon_gateway, :transports, [ReservedIdTransport])

    # The error happens during registry init which fails app start
    assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
  end

  test "enabled_transports filters by config" do
    Application.put_env(:lemon_gateway, :transports, [
      LemonGateway.Telegram.Transport,
      MockTransport
    ])

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    enabled = TransportRegistry.enabled_transports()
    enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

    # Mock transport is enabled by default, telegram is disabled
    assert "mock" in enabled_ids
    refute "telegram" in enabled_ids
  end

  test "telegram transport enabled when config says so" do
    Application.put_env(:lemon_gateway, :transports, [
      LemonGateway.Telegram.Transport,
      MockTransport
    ])

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: true
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    enabled = TransportRegistry.enabled_transports()
    enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

    assert "telegram" in enabled_ids
    assert "mock" in enabled_ids
  end

  # ===========================================================================
  # transport_enabled?/1 with different config formats
  # ===========================================================================

  describe "transport_enabled? with map config" do
    test "telegram disabled when enable_telegram is false" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end

    test "telegram disabled when enable_telegram key missing from map" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo"
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end
  end

  describe "transport_enabled? with keyword list config" do
    test "telegram enabled when enable_telegram is true in keyword list" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, [
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: true
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert "telegram" in enabled_ids
    end

    test "telegram disabled when enable_telegram is false in keyword list" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, [
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end

    test "telegram disabled when enable_telegram key missing from keyword list" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, [
        max_concurrent_runs: 1,
        default_engine: "echo"
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end
  end

  describe "transport_enabled? with empty/missing config" do
    test "telegram disabled when config is empty map" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{})

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end

    test "telegram disabled when config is empty keyword list" do
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end
  end

  # ===========================================================================
  # Reserved IDs rejection
  # ===========================================================================

  describe "reserved ID rejection" do
    test "rejects 'default' as reserved transport id" do
      Application.put_env(:lemon_gateway, :transports, [ReservedIdTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects 'all' as reserved transport id" do
      Application.put_env(:lemon_gateway, :transports, [ReservedAllTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end
  end

  # ===========================================================================
  # Invalid ID format rejection
  # ===========================================================================

  describe "invalid ID format rejection" do
    test "rejects ID with uppercase letters" do
      Application.put_env(:lemon_gateway, :transports, [InvalidIdTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects ID starting with number" do
      Application.put_env(:lemon_gateway, :transports, [NumericStartTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects ID with spaces" do
      Application.put_env(:lemon_gateway, :transports, [SpaceTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects empty ID" do
      Application.put_env(:lemon_gateway, :transports, [EmptyIdTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "rejects ID with special characters" do
      Application.put_env(:lemon_gateway, :transports, [SpecialCharsTransport])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "accepts ID with hyphens" do
      Application.put_env(:lemon_gateway, :transports, [ThirdTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert "third-transport" in ids
    end

    test "accepts ID with underscores" do
      Application.put_env(:lemon_gateway, :transports, [UnderscoreTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert "my_transport" in ids
    end

    test "accepts ID with numbers (not at start)" do
      Application.put_env(:lemon_gateway, :transports, [NumericTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert "transport123" in ids
    end
  end

  # ===========================================================================
  # enabled_transports/0 filtering logic
  # ===========================================================================

  describe "enabled_transports/0 filtering" do
    test "returns empty list when no transports registered" do
      Application.put_env(:lemon_gateway, :transports, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert TransportRegistry.enabled_transports() == []
    end

    test "returns all non-telegram transports when telegram disabled" do
      Application.put_env(:lemon_gateway, :transports, [
        MockTransport,
        AnotherTransport,
        LemonGateway.Telegram.Transport
      ])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        enable_telegram: false
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert length(enabled_ids) == 2
      assert "mock" in enabled_ids
      assert "another" in enabled_ids
      refute "telegram" in enabled_ids
    end

    test "returns tuples with {id, module}" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()

      assert [{"mock", MockTransport}] == enabled
    end

    test "returns all transports when all are enabled" do
      Application.put_env(:lemon_gateway, :transports, [
        MockTransport,
        AnotherTransport,
        LemonGateway.Telegram.Transport
      ])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        enable_telegram: true
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert length(enabled_ids) == 3
      assert "mock" in enabled_ids
      assert "another" in enabled_ids
      assert "telegram" in enabled_ids
    end
  end

  # ===========================================================================
  # Non-telegram transports handling
  # ===========================================================================

  describe "non-telegram transports" do
    test "non-telegram transports are always enabled by default" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{})

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert "mock" in enabled_ids
    end

    test "multiple non-telegram transports all enabled" do
      Application.put_env(:lemon_gateway, :transports, [
        MockTransport,
        AnotherTransport,
        ThirdTransport
      ])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{})

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert length(enabled_ids) == 3
      assert "mock" in enabled_ids
      assert "another" in enabled_ids
      assert "third-transport" in enabled_ids
    end

    test "non-telegram transports not affected by enable_telegram setting" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport])
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        enable_telegram: false
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert "mock" in enabled_ids
    end
  end

  # ===========================================================================
  # Registration edge cases
  # ===========================================================================

  describe "registration edge cases" do
    test "empty transport list results in empty registry" do
      Application.put_env(:lemon_gateway, :transports, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert TransportRegistry.list_transports() == []
    end

    test "single transport registration works" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert ids == ["mock"]
    end

    test "multiple transports all registered" do
      Application.put_env(:lemon_gateway, :transports, [
        MockTransport,
        AnotherTransport,
        ThirdTransport,
        UnderscoreTransport
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert length(ids) == 4
      assert "mock" in ids
      assert "another" in ids
      assert "third-transport" in ids
      assert "my_transport" in ids
    end

    test "get_transport returns correct module for each transport" do
      Application.put_env(:lemon_gateway, :transports, [
        MockTransport,
        AnotherTransport
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert TransportRegistry.get_transport("mock") == MockTransport
      assert TransportRegistry.get_transport("another") == AnotherTransport
    end

    test "get_transport! returns correct module" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert TransportRegistry.get_transport!("mock") == MockTransport
    end

    test "list_transports returns consistent results across calls" do
      Application.put_env(:lemon_gateway, :transports, [MockTransport, AnotherTransport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids1 = TransportRegistry.list_transports() |> Enum.sort()
      ids2 = TransportRegistry.list_transports() |> Enum.sort()

      assert ids1 == ids2
    end
  end

  # ===========================================================================
  # Default transports behavior
  # ===========================================================================

  describe "default transports" do
    test "uses telegram transport as default when no transports configured" do
      Application.delete_env(:lemon_gateway, :transports)

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      ids = TransportRegistry.list_transports()
      assert "telegram" in ids
    end
  end
end
