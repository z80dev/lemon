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

  defmodule InvalidIdTransport do
    use LemonGateway.Transport

    @impl true
    def id, do: "Invalid-ID"

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
end
