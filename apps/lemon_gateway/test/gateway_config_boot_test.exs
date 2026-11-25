defmodule LemonGateway.GatewayConfigBootTest do
  @moduledoc """
  The gateway reads `[gateway]` straight from the canonical config: no second
  config plane, no `[gateway.queue]` parser that can crash boot (#697), and an
  unloadable config fails boot instead of starting with channels off (#617).
  """
  use ExUnit.Case, async: false

  @replacement_key :"Elixir.LemonGateway.Config"

  setup do
    previous_replacement = Application.fetch_env(:lemon_gateway, @replacement_key)
    previous_ingress = Application.fetch_env(:lemon_gateway, :gateway_ingress_enabled)
    was_running? = is_pid(Process.whereis(LemonGateway.Supervisor))
    Application.stop(:lemon_gateway)
    Application.put_env(:lemon_gateway, :gateway_ingress_enabled, true)
    previous_home = System.get_env("HOME")

    home =
      Path.join(System.tmp_dir!(), "gateway_boot_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)
    Application.delete_env(:lemon_gateway, @replacement_key)
    LemonCore.ConfigCache.clear()

    on_exit(fn ->
      Application.stop(:lemon_gateway)

      for {key, previous} <- [
            {@replacement_key, previous_replacement},
            {:gateway_ingress_enabled, previous_ingress}
          ] do
        case previous do
          {:ok, value} -> Application.put_env(:lemon_gateway, key, value)
          :error -> Application.delete_env(:lemon_gateway, key)
        end
      end

      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      LemonCore.ConfigCache.clear()
      File.rm_rf!(home)
      if was_running?, do: Application.ensure_all_started(:lemon_gateway)
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
