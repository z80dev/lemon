defmodule LemonGateway.GatewayConfigBootTest do
  @moduledoc """
  The gateway reads `[gateway]` straight from the canonical config: no second
  config plane, no `[gateway.queue]` parser that can crash boot (#697), and an
  unloadable config fails boot instead of starting with channels off (#617).
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Slots

  @replacement_key :gateway_test_config

  setup do
    previous_replacement = Application.get_env(:lemon_core, @replacement_key)
    previous_home = System.get_env("HOME")

    home =
      Path.join(System.tmp_dir!(), "gateway_boot_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)
    Application.delete_env(:lemon_core, @replacement_key)
    LemonCore.ConfigCache.clear()

    on_exit(fn ->
      Application.put_env(:lemon_core, @replacement_key, previous_replacement)
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      LemonCore.ConfigCache.clear()
      File.rm_rf!(home)
    end)

    %{config_path: Path.join([home, ".lemon", "config.toml"])}
  end

  test "boots with every [gateway.queue] value the validator used to accept", %{
    config_path: path
  } do
    for mode <- ~w(fifo lifo priority collect followup steer), drop <- ~w(oldest newest reject) do
      File.write!(path, """
      [gateway]
      max_concurrent_runs = 4

      [gateway.queue]
      mode = "#{mode}"
      cap = 50
      drop = "#{drop}"
      """)

      LemonCore.ConfigCache.clear()
      name = :"#{__MODULE__}.Slots.#{mode}.#{drop}"
      start_supervised!({Slots, name: name}, id: name)

      assert {:ok, %{max: 4}} = Slots.stats(name)
      refute Map.has_key?(LemonCore.GatewayConfig.load(), :queue)
      stop_supervised!(name)
    end
  end

  test "an invalid [gateway] section fails boot", %{config_path: path} do
    File.write!(path, """
    [gateway]
    max_concurrent_runs = "many"
    enable_telegram = true
    """)

    LemonCore.ConfigCache.clear()
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {%LemonCore.Config.ValidationError{}, _stack}} =
               Slots.start_link(name: :"#{__MODULE__}.Invalid")
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "a binding with an unregistered transport creates no atom and still matches" do
    transport = "transport_#{System.unique_integer([:positive])}"

    settings = %{
      "gateway" => %{"bindings" => [%{"transport" => transport, "chat_id" => 1}]}
    }

    assert [%{transport: ^transport}] = LemonCore.Config.Gateway.resolve(settings).bindings
    assert_raise ArgumentError, fn -> String.to_existing_atom(transport) end
  end
end
