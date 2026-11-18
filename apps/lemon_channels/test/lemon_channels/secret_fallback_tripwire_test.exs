defmodule LemonChannels.SecretFallbackTripwireTest do
  @moduledoc """
  A configured credential secret that exists but cannot be read must stop the
  credential chain: no ambient env token or alternate configured key may be used.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Xmtp.Transport, as: XmtpTransport
  alias LemonChannels.Doctor.LiveChecks, as: Channels
  alias LemonCore.Doctor.LiveChecks
  alias LemonCore.{Secrets, Store}

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @tripwire "tripwire-credential-must-not-be-used"

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    name = "T07C_SECRET_#{System.unique_integer([:positive])}"
    env_keys = ["LEMON_SECRETS_MASTER_KEY", "DISCORD_BOT_TOKEN", "XMTP_T07C_KEY", name]
    original_env = Map.new(env_keys, &{&1, System.get_env(&1)})
    old_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_token = Application.get_env(:nostrum, :token)

    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("DISCORD_BOT_TOKEN", @tripwire)
    System.put_env("XMTP_T07C_KEY", @tripwire)
    System.put_env(name, @tripwire)
    Store.put(Secrets.table(), {"default", name}, "corrupt")

    on_exit(fn ->
      Store.delete(Secrets.table(), {"default", name})

      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore(:lemon_gateway, @gateway_config_key, old_gateway)
      restore(:nostrum, :token, old_token)
    end)

    assert {:error, reason} = Secrets.resolve(name)
    refute reason == :not_found

    %{name: name}
  end

  test "Discord supervisor does not fall back to DISCORD_BOT_TOKEN", %{name: name} do
    Application.put_env(:nostrum, :token, "untouched")

    assert {:ok, {_, []}} =
             LemonChannels.Adapters.Discord.Supervisor.init(config: %{bot_token_secret: name})

    assert Application.get_env(:nostrum, :token) == "untouched"
  end

  test "Discord doctor live check reports the secret error, not the fallback", %{name: name} do
    parent = self()

    opts = [
      config: %{gateway: %{enable_discord: true, discord: %{bot_token_secret: name}}},
      http_get: fn :get, {url, headers}, _, _ ->
        send(parent, {:request, to_string(url), headers})
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"username":"leaked"})}}
      end
    ]

    check =
      opts
      |> Channels.jobs()
      |> LiveChecks.run()
      |> Enum.find(&(&1.name == "channels.discord.live"))

    refute_received {:request, _, _}
    assert check.status == :fail
    assert check.message =~ "could not be resolved"
    refute inspect(check) =~ @tripwire
  end

  test "XMTP config drops alternate wallet keys when the wallet secret is unreadable",
       %{name: name} do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{
        wallet_key_secret: name,
        wallet_key: "${XMTP_T07C_KEY}",
        private_key: "${XMTP_T07C_KEY}"
      }
    })

    config = XmtpTransport.config()

    assert config[:wallet_key] == nil
    assert config[:private_key] == nil
    refute inspect(config) =~ @tripwire
    assert config[:wallet_key_error] != nil
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
