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

  # Stand-in for the running Telegram transport's `:update_allowlist` seam.
  defmodule FakeTransport do
    use GenServer

    def start_link(state),
      do: GenServer.start_link(__MODULE__, state, name: LemonChannels.Adapters.Telegram.Transport)

    def allowed(pid), do: GenServer.call(pid, :allowed)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:update_allowlist, op, id}, _from, state),
      do: {:reply, :ok, Pairing.put_allowlist("telegram", state, id, op)}

    def handle_call(:allowed, _from, state), do: {:reply, state.allowed_chat_ids, state}
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

    assert output =~ "channel is not running"
    content = File.read!(path)
    assert content =~ "# keep me"
    assert content =~ "bot_token_secret = \"bot\""

    assert {:ok, %{"gateway" => %{"telegram" => %{"allowed_chat_ids" => [42, 770_001]}}}} =
             Toml.decode(content)

    refute content =~ code
    assert {:error, :not_found} = Pairing.consume("telegram", code)
  end

  test "approve and revoke update the running transport and the config together", %{
    opts: opts,
    path: path
  } do
    name = LemonChannels.Adapters.Telegram.Transport
    refute Process.whereis(name), "a real Telegram transport is running; this test needs the name"
    {:ok, transport} = FakeTransport.start_link(%{allowed_chat_ids: [42]})
    File.write!(path, "[gateway.telegram]\nallowed_chat_ids = [42]\n")
    assert {:ok, code} = Pairing.request("telegram", 770_006, 99, "Alice")

    output =
      capture_io(fn -> assert PairingCommand.run(["approve", "telegram", code], opts) == 0 end)

    assert output =~ "no restart needed"
    assert FakeTransport.allowed(transport) == [42, 770_006]

    output =
      capture_io(fn -> assert PairingCommand.run(["revoke", "telegram", "770006"], opts) == 0 end)

    assert output =~ "rejects its next message"
    assert FakeTransport.allowed(transport) == [42]

    assert {:ok, %{"gateway" => %{"telegram" => %{"allowed_chat_ids" => [42]}}}} =
             path |> File.read!() |> Toml.decode()

    GenServer.stop(transport)
  end

  test "revoking the last Discord channel persists deny-all that startup preserves", %{
    opts: opts,
    path: path
  } do
    File.write!(path, "[gateway.discord]\nallowed_channel_ids = [42]\n")
    capture_io(fn -> assert PairingCommand.run(["revoke", "discord", "42"], opts) == 0 end)

    assert {:ok, %{"gateway" => %{"discord" => %{"allowed_channel_ids" => []}}}} =
             path |> File.read!() |> Toml.decode()

    # The persisted policy as the transport reads it on (re)start.
    %{allowed_channel_ids: persisted} =
      LemonCore.Config.cached(Path.dirname(Path.dirname(path)), cache: false).gateway.discord

    allowed = LemonChannels.Adapters.Discord.Transport.parse_allowed_channel_ids(persisted)
    assert allowed == MapSet.new()
  end

  test "revoke validates its chat id and leaves an unknown chat's config untouched", %{
    opts: opts,
    path: path
  } do
    capture_io(:stderr, fn ->
      assert PairingCommand.run(["revoke", "telegram", "not-a-chat"], opts) == 2
    end)

    File.write!(path, "[gateway.telegram]\nallowed_chat_ids = [42]\n")
    before = File.read!(path)
    capture_io(fn -> assert PairingCommand.run(["revoke", "telegram", "99"], opts) == 0 end)
    assert File.read!(path) == before
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
