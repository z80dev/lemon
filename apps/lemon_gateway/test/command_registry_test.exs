defmodule LemonGateway.CommandRegistryTest do
  use ExUnit.Case, async: false

  alias LemonGateway.CommandRegistry

  defmodule MockCommand do
    use LemonGateway.Command

    @impl true
    def name, do: "mock"

    @impl true
    def description, do: "A mock command"

    @impl true
    def handle(_scope, _args, _context), do: {:reply, "mocked"}
  end

  defmodule AnotherCommand do
    use LemonGateway.Command

    @impl true
    def name, do: "another"

    @impl true
    def description, do: "Another mock command"

    @impl true
    def handle(_scope, _args, _context), do: :ok
  end

  defmodule InvalidNameCommand do
    use LemonGateway.Command

    @impl true
    def name, do: "Invalid-Name"

    @impl true
    def description, do: "Bad name"

    @impl true
    def handle(_scope, _args, _context), do: :ok
  end

  defmodule ReservedNameCommand do
    use LemonGateway.Command

    @impl true
    def name, do: "help"

    @impl true
    def description, do: "Reserved"

    @impl true
    def handle(_scope, _args, _context), do: :ok
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
    Application.put_env(:lemon_gateway, :transports, [])

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, :commands)
    end)

    :ok
  end

  test "lists registered commands" do
    Application.put_env(:lemon_gateway, :commands, [MockCommand, AnotherCommand])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    names = CommandRegistry.list_commands()
    assert "mock" in names
    assert "another" in names
  end

  test "get_command returns module for valid name" do
    Application.put_env(:lemon_gateway, :commands, [MockCommand])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert CommandRegistry.get_command("mock") == MockCommand
  end

  test "get_command returns nil for unknown name" do
    Application.put_env(:lemon_gateway, :commands, [MockCommand])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert CommandRegistry.get_command("unknown") == nil
  end

  test "get_command! raises for unknown name" do
    Application.put_env(:lemon_gateway, :commands, [MockCommand])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert catch_exit(CommandRegistry.get_command!("unknown"))
  end

  test "all_commands returns list of tuples" do
    Application.put_env(:lemon_gateway, :commands, [MockCommand, AnotherCommand])
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    all = CommandRegistry.all_commands()
    assert {"mock", MockCommand} in all
    assert {"another", AnotherCommand} in all
  end

  test "rejects invalid command name format" do
    Application.put_env(:lemon_gateway, :commands, [InvalidNameCommand])

    # The error happens during registry init which fails app start
    assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
  end

  test "rejects reserved command name" do
    Application.put_env(:lemon_gateway, :commands, [ReservedNameCommand])

    # The error happens during registry init which fails app start
    assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
  end

  test "cancel command is registered by default" do
    Application.delete_env(:lemon_gateway, :commands)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert CommandRegistry.get_command("cancel") == LemonGateway.Commands.Cancel
  end
end
