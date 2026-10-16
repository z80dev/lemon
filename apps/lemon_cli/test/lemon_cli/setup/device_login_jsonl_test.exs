defmodule LemonCli.Setup.DeviceLoginJsonlTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias LemonCli.Setup.DeviceLogin
  alias LemonCore.Store

  @filter_bytes 1_048_576
  @store __MODULE__.PersistentStore
  @service __MODULE__.Service

  # Only provider transport is mocked. The complete Store/JSONL and lifecycle
  # processes are stopped and recreated against the same isolated directory.
  defmodule PersistentStore do
    def fetch(table, key), do: LemonCore.Store.fetch(__MODULE__, table, key)
    def put(table, key, value), do: LemonCore.Store.put(__MODULE__, table, key, value)
    def sync, do: LemonCore.Store.sync(__MODULE__)
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "device_login_jsonl_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    opts = start_runtime(root)
    {:ok, root: root, opts: opts}
  end

  test "high-bit positions persist and replay stays spent after the full runtime restarts", ctx do
    params = login_binding(high_bit_id("started"))
    assert {:ok, %{status: "starting"}} = DeviceLogin.start(params, ctx.opts)
    assert_receive {:mock_jsonl_provider_started, worker}
    monitor = Process.monitor(worker)
    assert_guard(params["loginId"], 1)
    opts = restart_runtime(ctx.root)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}

    assert {:ok, %{status: "lost"}} = DeviceLogin.poll(params, opts)
    assert {:ok, %{status: "lost"}} = DeviceLogin.start(params, opts)
    assert {:ok, %{status: "lost"}} = DeviceLogin.cancel(params, opts)
    refute_receive {:mock_jsonl_provider_started, _}, 20
    assert_guard(params["loginId"], 1)

    # Loading an existing guard must still allow a genuinely fresh intent.
    fresh = login_binding(high_bit_id("fresh"))
    assert {:ok, %{status: "starting"}} = DeviceLogin.start(fresh, opts)
    assert_receive {:mock_jsonl_provider_started, _}
    assert_guard(fresh["loginId"], 2)
  end

  test "cancel before start survives Store and lifecycle restart without contacting provider",
       ctx do
    params = login_binding(high_bit_id("cancelled-before-start"))
    assert {:ok, %{status: "cancelled"}} = DeviceLogin.cancel(params, ctx.opts)
    assert_guard(params["loginId"], 1)
    opts = restart_runtime(ctx.root)
    assert {:ok, %{status: "lost"}} = DeviceLogin.start(params, opts)
    assert {:ok, %{status: "lost"}} = DeviceLogin.cancel(params, opts)
    refute_receive {:mock_jsonl_provider_started, _}, 20
    assert_guard(params["loginId"], 1)
  end

  test "non-writing completion settlement remains single-use after full JSONL restart", ctx do
    params = login_binding(high_bit_id("settlement-login"))
    assert {:ok, %{status: "starting"}} = DeviceLogin.start(params, ctx.opts)
    assert_receive {:mock_jsonl_provider_started, worker}
    monitor = Process.monitor(worker)
    spent_id = high_bit_id("completion:restart")

    completion =
      Map.merge(params, %{
        "completionId" => String.replace_prefix(spent_id, "completion:", ""),
        "challengeNonce" => "",
        "commit" => false
      })

    assert {:ok, %{status: "cancelled"}} = DeviceLogin.complete(completion, ctx.opts)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_guard(spent_id, 2)
    opts = restart_runtime(ctx.root)
    assert_guard(spent_id, 2)

    replay =
      completion
      |> Map.put("commit", true)
      |> Map.put("challengeNonce", String.duplicate("A", 43))

    assert {:ok, %{status: "lost"}} = DeviceLogin.complete(replay, opts)

    assert {:ok, %{status: "lost"}} = DeviceLogin.start(params, opts)
    assert_guard(spent_id, 2)
    refute_receive {:mock_jsonl_provider_started, _}, 20
  end

  test "malformed or legacy persisted filters fail closed after JSONL replay", ctx do
    encoded = Base.encode64(:binary.copy(<<0>>, @filter_bytes))
    prefix = binary_part(encoded, 0, byte_size(encoded) - 3)

    invalid = [
      %{bits: :binary.copy(<<0>>, @filter_bytes), count: 1},
      %{bits_base64: "not-base64", count: 1},
      %{bits_base64: "!" <> binary_part(encoded, 1, byte_size(encoded) - 1), count: 1},
      %{bits_base64: prefix <> "B==", count: 1},
      %{bits_base64: Base.encode64(:binary.copy(<<0>>, @filter_bytes + 1)), count: 1},
      %{bits_base64: encoded, count: -1},
      %{bits_base64: encoded, count: 100_001},
      %{bits_base64: encoded, count: 1.0},
      %{bits_base64: encoded},
      %{bits_base64: encoded, count: 1, unexpected: true}
    ]

    for {guard, index} <- Enum.with_index(invalid) do
      assert :ok = PersistentStore.put(:provider_device_login, :spent_ids_v1, guard)
      assert :ok = PersistentStore.sync()
      opts = restart_runtime(ctx.root)
      params = login_binding("invalid-guard-#{index}")
      assert {:error, :unavailable} = DeviceLogin.start(params, opts)
      assert {:error, :unavailable} = DeviceLogin.cancel(params, opts)
      assert {:ok, ^guard} = PersistentStore.fetch(:provider_device_login, :spent_ids_v1)
      refute_receive {:mock_jsonl_provider_started, _}, 20
    end
  end

  defp start_runtime(root) do
    start_supervised!(
      {Store,
       name: @store,
       backend: LemonCore.Store.JsonlBackend,
       backend_opts: [path: root],
       cached_tables: []}
    )

    server = start_supervised!({DeviceLogin, name: @service, device_store: PersistentStore})
    parent = self()

    [
      target: %{id: "controller:jsonl-mock", nodeId: nil, hostname: "jsonl-mock"},
      device_server: server,
      device_login_fun: fn _opts ->
        send(parent, {:mock_jsonl_provider_started, self()})

        receive do
          :deny -> {:error, :access_denied}
        end
      end
    ]
  end

  defp restart_runtime(root) do
    assert :ok = stop_supervised(DeviceLogin)
    assert :ok = stop_supervised(Store)
    start_runtime(root)
  end

  defp login_binding(id) do
    %{
      "targetId" => "controller:jsonl-mock",
      "providerId" => "openai_codex",
      "loginId" => id,
      "ownerId" => "jsonl-mock-owner",
      "sessionId" => "jsonl-mock-session"
    }
  end

  defp high_bit_id(prefix) do
    Enum.find_value(1..1_000, fn index ->
      id = "#{prefix}-#{index}"
      if Enum.any?(positions(id), &(rem(&1, 8) == 7)), do: id
    end) || flunk("could not find deterministic high-bit hash position")
  end

  defp positions(id) do
    for <<position::unsigned-32 <- binary_part(:crypto.hash(:sha256, id), 0, 28)>>,
      do: rem(position, @filter_bytes * 8)
  end

  defp assert_guard(id, count) do
    assert {:ok, %{bits_base64: encoded, count: ^count} = guard} =
             PersistentStore.fetch(:provider_device_login, :spent_ids_v1)

    assert map_size(guard) == 2
    assert {:ok, bits} = Base.decode64(encoded)
    assert byte_size(bits) == @filter_bytes
    assert Base.encode64(bits) == encoded
    assert Enum.any?(positions(id), &(rem(&1, 8) == 7))

    for position <- positions(id) do
      assert band(:binary.at(bits, div(position, 8)), 1 <<< rem(position, 8)) != 0
    end
  end
end
