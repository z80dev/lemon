defmodule LemonGateway.GatewayConfigBootTest do
  @moduledoc """
  The gateway reads `[gateway]` straight from the canonical config: no second
  config plane, no `[gateway.queue]` parser that can crash boot (#697), and an
  unloadable config fails boot instead of starting with channels off (#617).
  """
  use ExUnit.Case, async: false

  import LemonGateway.Test.AppIsolation

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    isolate_gateway([], system_env: ["HOME"])

    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)
    Application.delete_env(:lemon_core, :gateway_test_config)
    LemonCore.ConfigCache.clear()

    on_exit(fn -> LemonCore.ConfigCache.clear() end)

    %{config_path: Path.join([home, ".lemon", "config.toml"])}
  end

  test "boots with every [gateway.queue] value the validator used to accept", %{
    config_path: path
  } do
    for mode <- ~w(fifo lifo priority collect followup steer), drop <- ~w(oldest newest reject) do
      File.write!(path, """
      [gateway]
      max_concurrent_runs = 4

      [gateway.ingress]
      enabled = true

      [gateway.queue]
      mode = "#{mode}"
      cap = 50
      drop = "#{drop}"
      """)

      LemonCore.ConfigCache.clear()
      assert {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      assert Process.whereis(LemonGateway.IngressSupervisor)
      assert LemonCore.GatewayConfig.get(:max_concurrent_runs) == 4
      refute Map.has_key?(LemonCore.GatewayConfig.load(), :queue)
      assert :ok = Application.stop(:lemon_gateway)
    end
  end

  test "an invalid [gateway] section fails boot", %{config_path: path} do
    File.write!(path, """
    [gateway]
    enable_telegram = "not-a-boolean"
    """)

    LemonCore.ConfigCache.clear()
    assert {:error, {:lemon_gateway, reason}} = Application.ensure_all_started(:lemon_gateway)
    assert inspect(reason) =~ "LemonCore.Config.ValidationError"
    refute Process.whereis(LemonGateway.IngressSupervisor)
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
