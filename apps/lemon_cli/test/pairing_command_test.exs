defmodule LemonCli.PairingCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias LemonChannels.Pairing
  alias LemonCli.PairingCommand
  alias LemonControlPlane.Methods.ChannelPairing
  alias LemonCore.Store

  defmodule LocalClient do
    def request("channels.pairing", params) do
      case ChannelPairing.handle(params, %{local?: true, auth: %{role: :operator}}) do
        {:ok, result} -> {:ok, result |> Jason.encode!() |> Jason.decode!()}
        error -> error
      end
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "lemon-pairing-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("HOME")
    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)
    config_path = Path.join(home, ".lemon/config.toml")

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{opts: [client: LocalClient, config_path: config_path], path: config_path}
  end

  test "approve appends the Telegram chat using setup's allowlist writer", %{
    opts: opts,
    path: path
  } do
    File.write!(
      path,
      "# keep me\n[gateway.telegram]\nallowed_chat_ids = [42]\nbot_token_secret = \"bot\"\n"
    )

    assert {:ok, code} = Pairing.request("telegram", 770_001, 99, "Alice")

    output =
      capture_io(fn -> assert PairingCommand.run(["approve", "telegram", code], opts) == 0 end)

    assert output =~ "Restart Lemon"
    content = File.read!(path)
    assert content =~ "# keep me"
    assert content =~ "bot_token_secret = \"bot\""

    assert {:ok, %{"gateway" => %{"telegram" => %{"allowed_chat_ids" => [42, 770_001]}}}} =
             Toml.decode(content)

    refute content =~ code
    assert {:error, :not_found} = Pairing.consume("telegram", code)
  end

  test "Discord approval appends allowed_channel_ids without changing guild policy", %{
    opts: opts,
    path: path
  } do
    File.write!(path, "[gateway.discord]\nallowed_channel_ids = [42]\nallowed_guild_ids = [43]\n")
    assert {:ok, code} = Pairing.request("discord", 770_002, 99, "Alice")
    capture_io(fn -> assert PairingCommand.run(["approve", "discord", code], opts) == 0 end)
    config = path |> File.read!() |> Toml.decode!()
    assert config["gateway"]["discord"]["allowed_channel_ids"] == [42, 770_002]
    assert config["gateway"]["discord"]["allowed_guild_ids"] == [43]
  end

  test "list masks chat IDs and never displays codes; deny consumes without config writes", %{
    opts: opts,
    path: path
  } do
    assert {:ok, code} = Pairing.request("telegram", 770_003, 99, "Alice")
    output = capture_io(fn -> assert PairingCommand.run(["list"], opts) == 0 end)
    assert output =~ "***0003"
    assert output =~ "Alice"
    refute output =~ code
    refute output =~ "770003"
    capture_io(fn -> assert PairingCommand.run(["deny", "telegram", code], opts) == 0 end)
    refute File.exists?(path)
    assert {:error, :not_found} = Pairing.consume("telegram", code)
  end

  test "expired and wrong-platform codes fail without config mutation", %{opts: opts, path: path} do
    assert {:ok, code} = Pairing.request("telegram", 770_004, 99, "Alice")

    capture_io(:stderr, fn ->
      assert PairingCommand.run(["approve", "discord", code], opts) == 1
    end)

    {key, row} =
      Enum.find(Store.list(:channel_pairing_requests), fn {_key, row} ->
        row.chat_id == "770004"
      end)

    assert :ok = Store.put(:channel_pairing_requests, key, %{row | expires_at: 0})

    error =
      capture_io(:stderr, fn ->
        assert PairingCommand.run(["approve", "telegram", code], opts) == 1
      end)

    refute error =~ code
    refute File.exists?(path)
  end

  test "pairing method refuses remote operators and nodes before consuming a code" do
    assert {:ok, code} = Pairing.request("telegram", 770_005, 99, "Alice")
    params = %{"action" => "consume", "platform" => "telegram", "pairing_code" => code}

    assert {:error, :forbidden, _, nil} =
             ChannelPairing.handle(params, %{local?: false, auth: %{role: :operator}})

    assert {:error, :forbidden, _, nil} =
             ChannelPairing.handle(params, %{local?: true, auth: %{role: :node}})

    assert ChannelPairing.scopes() == [:pairing]
    assert {:ok, _} = Pairing.consume("telegram", code)
  end

  test "invalid arguments are usage errors and do not echo code-like input", %{opts: opts} do
    error =
      capture_io(:stderr, fn ->
        assert PairingCommand.run(["approve", "sms", "ABCD2345"], opts) == 2
      end)

    refute error =~ "ABCD2345"
  end
end
