defmodule LemonCli.Setup.DeviceLoginTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCli.Setup.{DeviceLogin, ProviderManagement}

  # Deliberate mocks: no provider requests, user credentials or global config.
  defmodule MockStore do
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{guard: nil, fail: nil} end, name: __MODULE__)
    def fetch(:provider_device_login, :spent_ids_v1), do: Agent.get(__MODULE__, &{:ok, &1.guard})
    def seed(guard), do: Agent.update(__MODULE__, &%{&1 | guard: guard})
    def fail(operation), do: Agent.update(__MODULE__, &%{&1 | fail: operation})
    def contents, do: Agent.get(__MODULE__, & &1.guard)

    def put(:provider_device_login, :spent_ids_v1, guard) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.fail == :put,
          do: {{:error, :mock_failure}, state},
          else: {:ok, %{state | guard: guard}}
      end)
    end

    def sync do
      Agent.get(__MODULE__, fn state ->
        if state.fail == :sync, do: {:error, :mock_failure}, else: :ok
      end)
    end
  end

  defmodule MockSecrets do
    use Agent

    def start_link(_) do
      Agent.start_link(fn -> %{values: %{}, writes: 0, snapshot_owner: nil} end, name: __MODULE__)
    end

    def values, do: Agent.get(__MODULE__, & &1.values)
    def writes, do: Agent.get(__MODULE__, & &1.writes)
    def get(name), do: Agent.get(__MODULE__, &Map.fetch(&1.values, name)) |> found()
    def block_snapshot(parent), do: Agent.update(__MODULE__, &%{&1 | snapshot_owner: parent})

    def snapshot(name) do
      if parent = Agent.get(__MODULE__, & &1.snapshot_owner) do
        send(parent, {:snapshot_waiting, self()})

        receive do
          :continue_snapshot -> :ok
        end
      end

      get(name)
    end

    def restore(name, value), do: set(name, value, [])
    def delete(name), do: Agent.update(__MODULE__, &%{&1 | values: Map.delete(&1.values, name)})

    def set(name, value, _opts) do
      Agent.update(
        __MODULE__,
        &%{&1 | values: Map.put(&1.values, name, value), writes: &1.writes + 1}
      )

      {:ok, %{}}
    end

    defp found(:error), do: {:error, :not_found}
    defp found(value), do: value
  end

  setup do
    root = Path.join(System.tmp_dir!(), "device_login_mock_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    start_supervised!(MockStore)
    start_supervised!(MockSecrets)
    server = start_service()
    parent = self()
    previous_req = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(__MODULE__, fn _ -> flunk("mock lifecycle must never contact a provider") end)

    on_exit(fn ->
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})
      File.rm_rf!(root)
    end)

    login = fn opts ->
      Keyword.fetch!(opts, :on_device_code).(metadata())
      send(parent, {:mock_started, self()})

      receive do
        :complete -> {:ok, secret()}
        :deny -> {:error, :access_denied}
        :expire -> {:error, :device_flow_timed_out}
        :raise -> raise "private-access private-refresh private-device"
        :exit -> exit({:private_failure, "private-access private-refresh private-device"})
      end
    end

    opts = [
      target: %{id: "controller:mock-device", nodeId: nil, hostname: "mock-target"},
      device_server: server,
      device_login_fun: login,
      config_path: Path.join(root, "config.toml"),
      cwd: root,
      secrets: MockSecrets,
      reload_fun: fn -> :ok end
    ]

    params = %{
      "targetId" => "controller:mock-device",
      "providerId" => "openai_codex",
      "loginId" => "mock-client-nonce-1",
      "ownerId" => "opaque-owner-binding",
      "sessionId" => "opaque-session-binding"
    }

    {:ok, opts: opts, params: params, root: root}
  end

  test "start/poll expose only public fields; current completion stores once without changing defaults",
       ctx do
    File.write!(
      ctx.opts[:config_path],
      "[defaults]\nprovider = \"anthropic\"\nmodel = \"kept-model\"\n"
    )

    assert {:ok, %{status: "starting"} = starting} =
             ProviderManagement.device_start(ctx.params, ctx.opts)

    assert_public(starting)
    assert_empty_fields(starting)
    assert_receive {:mock_started, worker}

    assert {:ok, %{status: "pending"} = pending} =
             ProviderManagement.device_poll(ctx.params, ctx.opts)

    assert_public(pending)
    assert pending.verificationUrl == "https://auth.openai.com/codex/device"
    assert pending.userCode == "MOCK-123"
    assert pending.pollIntervalMs == 8_000
    assert {:ok, ^pending} = ProviderManagement.device_start(ctx.params, ctx.opts)
    refute_receive {:mock_started, _}, 10
    assert MockSecrets.values() == %{}
    monitor = Process.monitor(worker)
    send(worker, :complete)
    completed = await_status(ctx.params, ctx.opts, "completed")
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_empty_fields(completed)
    assert_public(completed)
    assert MockSecrets.writes() == 1
    assert {:ok, ^completed} = ProviderManagement.device_poll(ctx.params, ctx.opts)
    assert {:ok, ^completed} = ProviderManagement.device_cancel(ctx.params, ctx.opts)
    assert {:ok, ^completed} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert MockSecrets.writes() == 1
    config = Toml.decode_file!(ctx.opts[:config_path])
    assert config["defaults"] == %{"provider" => "anthropic", "model" => "kept-model"}
    provider = config["providers"]["openai-codex"]
    assert provider["auth_source"] == "oauth"
    stored = Jason.decode!(MockSecrets.values()[provider["oauth_secret"]])
    assert Map.drop(stored, ["expires_at_ms"]) == Map.drop(secret(), ["expires_at_ms"])
    assert stored["expires_at_ms"] > System.system_time(:millisecond)
    refute File.read!(ctx.opts[:config_path]) =~ "private-"
    refute inspect(:sys.get_state(ctx.opts[:device_server])) =~ "private-"
    refute inspect(:sys.get_status(ctx.opts[:device_server])) =~ "private-"
  end

  test "every binding is compared and malformed inputs fail before launch", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, _}

    for operation <- [
          &ProviderManagement.device_start/2,
          &ProviderManagement.device_poll/2,
          &ProviderManagement.device_cancel/2
        ] do
      for key <- ["ownerId", "sessionId"] do
        assert {:error, :forbidden} =
                 operation.(Map.put(ctx.params, key, "another-binding"), ctx.opts)
      end

      other_target = Map.put(ctx.params, "targetId", "controller:other")
      assert {:error, :invalid_target} = operation.(other_target, ctx.opts)

      other_opts =
        Keyword.put(ctx.opts, :target, %{id: "controller:other", nodeId: nil, hostname: "other"})

      assert {:error, :forbidden} = operation.(other_target, other_opts)

      assert {:error, :invalid_provider} =
               operation.(Map.put(ctx.params, "providerId", "openai-codex"), ctx.opts)

      for bad <- [nil, "", String.duplicate("x", 257), "a\nb", <<255>>] do
        for key <- Map.keys(ctx.params) do
          assert {:error, :invalid_request} = operation.(Map.put(ctx.params, key, bad), ctx.opts)
        end
      end

      assert {:error, :invalid_request} = operation.(Map.delete(ctx.params, "ownerId"), ctx.opts)

      assert {:error, :invalid_request} =
               operation.(Map.put(ctx.params, "secret", "private-device"), ctx.opts)
    end

    assert {:ok, %{status: "pending"}} = ProviderManagement.device_poll(ctx.params, ctx.opts)
    assert MockSecrets.values() == %{}
  end

  test "new login supersedes the same owner target provider across sessions and stale completion cannot persist",
       ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, old_worker}
    old_ref = :sys.get_state(ctx.opts[:device_server]).entries[ctx.params["loginId"]].ref
    monitor = Process.monitor(old_worker)
    next = %{ctx.params | "loginId" => "new-fixed-nonce", "sessionId" => "new-product-session"}
    assert {:ok, _} = ProviderManagement.device_start(next, ctx.opts)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, :killed}
    assert_receive {:mock_started, worker}
    assert {:ok, %{status: "cancelled"}} = ProviderManagement.device_poll(ctx.params, ctx.opts)

    assert :ok =
             GenServer.call(
               ctx.opts[:device_server],
               {:complete, ctx.params["loginId"], old_ref,
                fn -> flunk("stale completion must not persist") end}
             )

    send(ctx.opts[:device_server], {:worker_finished, ctx.params["loginId"], old_ref, "failed"})
    assert {:ok, %{status: "cancelled"}} = ProviderManagement.device_poll(ctx.params, ctx.opts)
    assert MockSecrets.values() == %{}
    send(worker, :complete)
    await_status(next, ctx.opts, "completed")
    assert MockSecrets.writes() == 1
  end

  test "different owners and targets remain independent", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, first}
    other_owner = %{ctx.params | "loginId" => "other-owner-login", "ownerId" => "other-owner"}
    assert {:ok, _} = ProviderManagement.device_start(other_owner, ctx.opts)
    assert_receive {:mock_started, second}

    other_target = %{
      ctx.params
      | "loginId" => "other-target-login",
        "targetId" => "node:mock-other"
    }

    other_opts =
      Keyword.put(ctx.opts, :target, %{
        id: "node:mock-other",
        nodeId: "mock-other",
        hostname: "other"
      })

    assert {:ok, _} = ProviderManagement.device_start(other_target, other_opts)
    assert_receive {:mock_started, third}
    assert Process.alive?(first) and Process.alive?(second) and Process.alive?(third)
    assert {:ok, %{status: "cancelled"}} = ProviderManagement.device_cancel(other_owner, ctx.opts)
    assert Process.alive?(first) and Process.alive?(third)
  end

  test "out-of-order cancel before start consumes the fixed ID without a provider request", ctx do
    assert {:ok, %{status: "cancelled"} = cancelled} =
             ProviderManagement.device_cancel(ctx.params, ctx.opts)

    assert_empty_fields(cancelled)
    assert {:ok, ^cancelled} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert {:ok, ^cancelled} = ProviderManagement.device_cancel(ctx.params, ctx.opts)
    refute_receive {:mock_started, _}, 10
    assert MockSecrets.values() == %{}
    assert MockStore.contents().count == 1

    assert :ok = stop_supervised(DeviceLogin)
    opts = Keyword.put(ctx.opts, :device_server, start_service())
    assert {:ok, %{status: "lost"}} = ProviderManagement.device_start(ctx.params, opts)
    refute_receive {:mock_started, _}, 10
  end

  test "cancel before completion is final and duplicate cancellation never reconnects", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    monitor = Process.monitor(worker)

    assert {:ok, %{status: "cancelled"} = cancelled} =
             ProviderManagement.device_cancel(ctx.params, ctx.opts)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    send(worker, :complete)
    assert {:ok, ^cancelled} = ProviderManagement.device_cancel(ctx.params, ctx.opts)
    assert {:ok, ^cancelled} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_empty_fields(cancelled)
    assert MockSecrets.values() == %{}
    refute File.exists?(ctx.opts[:config_path])
  end

  test "completion already persisting wins a subsequent cancel in the same serialization", ctx do
    parent = self()

    opts =
      Keyword.put(ctx.opts, :reload_fun, fn ->
        send(parent, {:persisting, self()})

        receive do
          :release_persistence -> :ok
        end
      end)

    assert {:ok, _} = ProviderManagement.device_start(ctx.params, opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, opts)
    completion = Task.async(fn -> authorize(ctx.params, opts) end)
    assert_receive {:persisting, manager}
    tag = make_ref()
    send(manager, {:"$gen_call", {self(), tag}, {:cancel, ctx.params, opts}})
    send(manager, :release_persistence)
    assert_receive {^tag, {:ok, %{status: "completed"}}}
    assert MockSecrets.writes() == 1
    assert {:ok, %{status: "completed"}} = Task.await(completion)
  end

  test "expiry and denial are terminal, public and never persist credentials", ctx do
    for {command, status, id} <- [
          {:deny, "denied", "denied-login"},
          {:expire, "expired", "expired-login"}
        ] do
      params = %{ctx.params | "loginId" => id}
      assert {:ok, _} = ProviderManagement.device_start(params, ctx.opts)
      assert_receive {:mock_started, worker}
      send(worker, command)
      result = await_status(params, ctx.opts, status)
      assert_empty_fields(result)
      assert_public(result)
      assert {:ok, ^result} = ProviderManagement.device_start(params, ctx.opts)
    end

    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    monitor = Process.monitor(worker)

    :sys.replace_state(ctx.opts[:device_server], fn state ->
      update_in(state, [:entries, ctx.params["loginId"], :deadline], fn _ ->
        System.monotonic_time(:millisecond) - 1
      end)
    end)

    assert {:ok, %{status: "expired"}} = ProviderManagement.device_poll(ctx.params, ctx.opts)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert MockSecrets.values() == %{}
  end

  test "restart and terminal pruning return lost even when replaying start", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    assert :ok = stop_supervised(DeviceLogin)
    refute Process.alive?(worker)
    restarted = Keyword.put(ctx.opts, :device_server, start_service())

    for operation <- [
          &ProviderManagement.device_start/2,
          &ProviderManagement.device_poll/2,
          &ProviderManagement.device_cancel/2
        ] do
      assert {:ok, %{status: "lost"} = lost} = operation.(ctx.params, restarted)
      assert_empty_fields(lost)
    end

    refute_receive {:mock_started, _}, 10
    next = %{ctx.params | "loginId" => "pruned-login"}
    assert {:ok, _} = ProviderManagement.device_start(next, restarted)
    assert_receive {:mock_started, _}
    assert {:ok, _} = ProviderManagement.device_cancel(next, restarted)

    :sys.replace_state(restarted[:device_server], fn state ->
      update_in(state, [:entries, next["loginId"], :finished_at], fn _ ->
        System.monotonic_time(:millisecond) - 900_001
      end)
    end)

    assert {:ok, %{status: "lost"}} = ProviderManagement.device_start(next, restarted)
    assert {:ok, %{status: "lost"}} = ProviderManagement.device_poll(next, restarted)
    assert MockSecrets.values() == %{}
    guard = MockStore.contents()
    assert Map.keys(guard) |> Enum.sort() == [:bits_base64, :count]
    assert byte_size(Base.decode64!(guard.bits_base64)) == 1_048_576
    assert guard.count == 2
  end

  test "active and retained record capacities are bounded; durable capacity never clears", ctx do
    for index <- 1..16 do
      params = %{ctx.params | "loginId" => "active-#{index}", "ownerId" => "owner-#{index}"}
      assert {:ok, _} = ProviderManagement.device_start(params, ctx.opts)
      assert_receive {:mock_started, _}
    end

    assert {:error, :busy} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert MockStore.contents().count == 16
    assert map_size(:sys.get_state(ctx.opts[:device_server]).entries) == 16

    for index <- 1..16 do
      params = %{ctx.params | "loginId" => "active-#{index}", "ownerId" => "owner-#{index}"}
      assert {:ok, _} = ProviderManagement.device_cancel(params, ctx.opts)
    end

    for index <- 17..128 do
      params = %{ctx.params | "loginId" => "retained-#{index}"}
      assert {:ok, _} = ProviderManagement.device_start(params, ctx.opts)
      assert_receive {:mock_started, _}
      assert {:ok, _} = ProviderManagement.device_cancel(params, ctx.opts)
    end

    assert {:error, :busy} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert map_size(:sys.get_state(ctx.opts[:device_server]).entries) == 128
    assert MockStore.contents().count == 128
    MockStore.seed(%{bits_base64: Base.encode64(:binary.copy(<<0>>, 1_048_576)), count: 100_000})
    assert :ok = stop_supervised(DeviceLogin)
    opts = Keyword.put(ctx.opts, :device_server, start_service())
    assert {:error, :busy} = ProviderManagement.device_start(ctx.params, opts)
    assert MockSecrets.values() == %{}
  end

  test "durable guard failure refuses provider work, including uncertain sync", ctx do
    MockStore.fail(:put)
    assert {:error, :unavailable} = ProviderManagement.device_start(ctx.params, ctx.opts)
    refute_receive {:mock_started, _}, 10
    MockStore.fail(:sync)
    assert {:error, :unavailable} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert {:ok, %{status: "lost"}} = ProviderManagement.device_start(ctx.params, ctx.opts)
    refute_receive {:mock_started, _}, 10
    assert MockSecrets.values() == %{}
  end

  test "disconnect and API-key replacement cancel pending grants before mutation", ctx do
    for operation <- [:disconnect, :set_api_key] do
      params = %{ctx.params | "loginId" => "credential-mutation-#{operation}"}
      assert {:ok, _} = ProviderManagement.device_start(params, ctx.opts)
      assert_receive {:mock_started, worker}
      monitor = Process.monitor(worker)

      result =
        case operation do
          :disconnect ->
            ProviderManagement.disconnect("openai_codex", ctx.opts)

          :set_api_key ->
            ProviderManagement.set_api_key("openai_codex", "mock-replacement-token", ctx.opts)
        end

      assert {:ok, _} = result
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert {:ok, %{status: "cancelled"}} = ProviderManagement.device_poll(params, ctx.opts)
    end
  end

  test "invalid provider metadata and worker exceptions never echo or log secrets", ctx do
    logs =
      capture_log(fn ->
        for command <- [:raise, :exit] do
          params = %{ctx.params | "loginId" => "failure-#{command}"}
          assert {:ok, _} = ProviderManagement.device_start(params, ctx.opts)
          assert_receive {:mock_started, worker}
          send(worker, command)
          result = await_status(params, ctx.opts, "failed")
          refute inspect(result) =~ "private-"
        end

        for metadata <- [
              %{metadata() | verification_url: "https://attacker.invalid/private-device"},
              %{metadata() | user_code: "private-device?secret=value"},
              %{metadata() | user_code: String.duplicate("A", 65)},
              %{metadata() | expires_at_ms: System.system_time(:millisecond) + 1_000_000},
              %{metadata() | poll_interval_ms: 60_001}
            ] do
          params = %{
            ctx.params
            | "loginId" => "invalid-metadata-#{System.unique_integer([:positive])}"
          }

          opts =
            Keyword.put(ctx.opts, :device_login_fun, fn opts ->
              Keyword.fetch!(opts, :on_device_code).(metadata)
              {:ok, secret()}
            end)

          assert {:ok, _} = ProviderManagement.device_start(params, opts)
          assert_public(await_status(params, opts, "failed"))
        end
      end)

    refute logs =~ "private-"
    refute inspect(:sys.get_status(ctx.opts[:device_server])) =~ "private-"
    assert MockSecrets.values() == %{}
  end

  test "persistence failure is failed with compensation rather than completed", ctx do
    opts =
      Keyword.put(ctx.opts, :write_fun, fn _, _ -> raise "private-access private-refresh" end)

    logs =
      capture_log(fn ->
        assert {:ok, _} = ProviderManagement.device_start(ctx.params, opts)
        assert_receive {:mock_started, worker}
        send(worker, :complete)
        result = await_status(ctx.params, opts, "failed")
        assert_empty_fields(result)
      end)

    refute logs =~ "private-"
    assert MockSecrets.values() == %{}
    refute File.exists?(ctx.opts[:config_path])
  end

  test "successful mock OAuth never writes without fresh completion authorization",
       ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    assert {:ok, %{status: "pending"}} = ProviderManagement.device_poll(ctx.params, ctx.opts)
    assert MockSecrets.writes() == 0
    refute File.exists?(ctx.opts[:config_path])
    refute inspect(:sys.get_state(ctx.opts[:device_server])) =~ "private-"
  end

  test "non-writing settlement consumes a delayed completion across node re-pairing", ctx do
    opts = Keyword.put(ctx.opts, :authority, {self(), 1})
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, opts)
    monitor = Process.monitor(worker)
    completion = %{"completionId" => "settled-after-repair"}
    repaired = Keyword.put(opts, :authority, {self(), 2})

    assert {:ok, %{status: "cancelled"}} =
             authorize(ctx.params, repaired, Map.put(completion, "commit", false))

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert {:ok, %{status: "cancelled"}} = authorize(ctx.params, opts, completion)
    assert MockSecrets.writes() == 0
    refute File.exists?(ctx.opts[:config_path])

    assert :ok = stop_supervised(DeviceLogin)
    restarted = Keyword.put(repaired, :device_server, start_service())
    assert {:ok, %{status: "lost"}} = authorize(ctx.params, restarted, completion)
    assert MockSecrets.writes() == 0
    next = Map.put(ctx.params, "loginId", "explicit-login-after-repair")
    assert {:ok, _} = ProviderManagement.device_start(next, restarted)
    assert_receive {:mock_started, next_worker}
    send(next_worker, :complete)
    await_status(next, restarted, "completed")
    assert MockSecrets.writes() == 1
  end

  test "revoked controller connection and replaced node generation cannot complete a successful OAuth",
       ctx do
    for {initial, revoked} <- [
          {self(), spawn(fn -> :ok end)},
          {{self(), 1}, {self(), 2}}
        ] do
      params = Map.put(ctx.params, "loginId", "authority-#{System.unique_integer([:positive])}")
      opts = Keyword.put(ctx.opts, :authority, initial)
      assert {:ok, _} = ProviderManagement.device_start(params, opts)
      assert_receive {:mock_started, worker}
      send(worker, :complete)
      await_ready(params, opts)

      assert {:ok, %{status: "cancelled"}} =
               authorize(params, Keyword.put(opts, :authority, revoked))

      assert MockSecrets.writes() == 0
      refute File.exists?(ctx.opts[:config_path])
    end
  end

  test "expired completion authorization never persists successful mock OAuth", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)

    assert {:ok, %{status: "cancelled"}} =
             authorize(ctx.params, ctx.opts, %{"challengeNonce" => "expired-nonce"})

    assert MockSecrets.writes() == 0
    refute File.exists?(ctx.opts[:config_path])
  end

  test "duplicate settlement reconciles an accepted completion without retrying its write",
       ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    :erlang.suspend_process(worker)

    try do
      completion = %{"completionId" => "concurrent-fixed-completion"}
      original = Task.async(fn -> authorize(ctx.params, ctx.opts, completion) end)
      await_completion(ctx.params, ctx.opts)

      settlement =
        Task.async(fn ->
          authorize(ctx.params, ctx.opts, Map.put(completion, "commit", false))
        end)

      assert Task.yield(settlement, 10) == nil
      assert MockSecrets.writes() == 0
      :erlang.resume_process(worker)
      assert {:ok, %{status: "completed"}} = Task.await(original)
      assert {:ok, %{status: "completed"}} = Task.await(settlement)
      assert MockSecrets.writes() == 1
    after
      try do
        :erlang.resume_process(worker)
      catch
        :error, _ -> :ok
      end
    end
  end

  test "exact binding rejection proves that completion cannot write", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    foreign = Map.put(ctx.params, "sessionId", "another-authenticated-product-session")

    assert {:error, :provider_binding_rejected} = authorize(foreign, ctx.opts)

    assert {:error, :provider_binding_rejected} =
             authorize(foreign, ctx.opts, %{"commit" => false})

    assert MockSecrets.writes() == 0
    assert {:ok, %{status: "completed"}} = authorize(ctx.params, ctx.opts)
    assert MockSecrets.writes() == 1
  end

  test "a mismatched challenge is refused and drops successful OAuth", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    monitor = Process.monitor(worker)

    assert {:ok, %{status: "cancelled"}} =
             authorize(ctx.params, ctx.opts, %{"challengeNonce" => "foreign-nonce"})

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert MockSecrets.writes() == 0
  end

  test "expiry is checked again when an accepted worker reaches serialized completion", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    :erlang.suspend_process(worker)

    try do
      completion = Task.async(fn -> authorize(ctx.params, ctx.opts) end)
      await_completion(ctx.params, ctx.opts)

      :sys.replace_state(ctx.opts[:device_server], fn state ->
        put_in(
          state,
          [:entries, ctx.params["loginId"], :authorization_deadline],
          System.monotonic_time(:millisecond) - 1
        )
      end)

      :erlang.resume_process(worker)
      assert {:ok, %{status: "cancelled"}} = Task.await(completion)
      assert MockSecrets.writes() == 0
      refute File.exists?(ctx.opts[:config_path])
    after
      try do
        :erlang.resume_process(worker)
      catch
        :error, _ -> :ok
      end
    end
  end

  test "expiry inside the config lock refuses a queued credential transaction", ctx do
    MockSecrets.block_snapshot(self())
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)
    opts = Keyword.put(ctx.opts, :device_monotonic_time, fn -> Agent.get(clock, & &1) end)

    :sys.replace_state(ctx.opts[:device_server], fn state ->
      put_in(
        state,
        [:entries, ctx.params["loginId"], :challenge_clock],
        opts[:device_monotonic_time]
      )
    end)

    completion =
      Task.async(fn ->
        authorize(ctx.params, opts)
      end)

    try do
      assert_receive {:snapshot_waiting, manager}, 1_000
      Agent.update(clock, fn _ -> 6_000 end)
      send(manager, :continue_snapshot)
      assert {:ok, %{status: "cancelled"}} = Task.await(completion)
      assert MockSecrets.writes() == 0
      refute File.exists?(ctx.opts[:config_path])
    after
      send(ctx.opts[:device_server], :continue_snapshot)
    end
  end

  test "challenge is ready-only, private, authority-bound and never extends on repeated reads",
       ctx do
    {:ok, clock} = Agent.start_link(fn -> 1_000 end)
    opts = Keyword.put(ctx.opts, :device_monotonic_time, fn -> Agent.get(clock, & &1) end)
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, opts)
    assert_receive {:mock_started, worker}
    assert {:ok, %{challengeNonce: nil}} = ProviderManagement.device_challenge(ctx.params, opts)
    send(worker, :complete)
    await_ready(ctx.params, opts)
    # Delivery may be delayed long after OAuth becomes ready; issuance starts TTL.
    Agent.update(clock, fn _ -> 10_000 end)

    assert {:ok, %{challengeNonce: nonce} = challenge} =
             ProviderManagement.device_challenge(ctx.params, opts)

    assert {:ok, bytes} = Base.url_decode64(nonce, padding: false)
    assert byte_size(bytes) == 32
    assert_public(Map.delete(challenge, :challengeNonce))
    assert {:ok, public} = ProviderManagement.device_poll(ctx.params, opts)
    assert_public(public)

    assert {:ok, %{challengeNonce: nil}} =
             ProviderManagement.device_challenge(
               ctx.params,
               Keyword.put(opts, :authority, :foreign)
             )

    Agent.update(clock, fn _ -> 14_999 end)

    assert {:ok, %{challengeNonce: ^nonce}} =
             ProviderManagement.device_challenge(ctx.params, opts)

    Agent.update(clock, fn _ -> 15_000 end)

    assert {:ok, %{status: "cancelled"}} =
             authorize(ctx.params, opts, %{"challengeNonce" => nonce})

    assert MockSecrets.writes() == 0
  end

  test "completion ignores forward skew and backward wall clock changes", ctx do
    for skew <- [86_400_000, -86_400_000] do
      {:ok, wall} = Agent.start_link(fn -> System.system_time(:millisecond) end)
      opts = Keyword.put(ctx.opts, :device_wall_time, fn -> Agent.get(wall, & &1) end)
      params = Map.put(ctx.params, "loginId", "wall-skew-#{skew}")
      assert {:ok, _} = ProviderManagement.device_start(params, opts)
      assert_receive {:mock_started, worker}
      send(worker, :complete)
      await_ready(params, opts)
      assert {:ok, %{challengeNonce: nonce}} = ProviderManagement.device_challenge(params, opts)
      Agent.update(wall, &(&1 + skew))

      assert {:ok, %{status: "completed"}} =
               authorize(params, opts, %{"challengeNonce" => nonce})
    end

    assert MockSecrets.writes() == 2
  end

  test "restart invalidates an issued challenge without persisting it", ctx do
    assert {:ok, _} = ProviderManagement.device_start(ctx.params, ctx.opts)
    assert_receive {:mock_started, worker}
    send(worker, :complete)
    await_ready(ctx.params, ctx.opts)

    assert {:ok, %{challengeNonce: nonce}} =
             ProviderManagement.device_challenge(ctx.params, ctx.opts)

    refute inspect(MockStore.contents()) =~ nonce
    assert :ok = stop_supervised(DeviceLogin)
    restarted = Keyword.put(ctx.opts, :device_server, start_service())

    assert {:ok, %{challengeNonce: nil, status: "lost"}} =
             ProviderManagement.device_challenge(ctx.params, restarted)

    assert {:ok, %{status: "lost"}} =
             authorize(ctx.params, restarted, %{"challengeNonce" => nonce})

    assert MockSecrets.writes() == 0
  end

  defp start_service do
    start_supervised!({DeviceLogin, name: __MODULE__.Service, device_store: MockStore})
  end

  defp metadata do
    %{
      verification_url: "https://auth.openai.com/codex/device",
      user_code: "MOCK-123",
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      poll_interval_ms: 8_000
    }
  end

  defp secret do
    %{
      "type" => "openai_codex_oauth",
      "access_token" => "private-access",
      "refresh_token" => "private-refresh",
      "account_id" => "mock-account",
      "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
    }
  end

  defp assert_public(result) do
    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(
               ~w(loginId targetId providerId status verificationUrl userCode expiresAtMs pollIntervalMs)a
             )

    refute inspect(result) =~ "private-"
  end

  defp assert_empty_fields(result) do
    assert Map.take(result, ~w(verificationUrl userCode expiresAtMs pollIntervalMs)a) == %{
             verificationUrl: nil,
             userCode: nil,
             expiresAtMs: nil,
             pollIntervalMs: nil
           }
  end

  defp await_completion(params, opts, attempts \\ 200) do
    if :sys.get_state(opts[:device_server]).entries[params["loginId"]].completion_from do
      :ok
    else
      assert attempts > 0
      Process.sleep(5)
      await_completion(params, opts, attempts - 1)
    end
  end

  defp await_ready(params, opts, attempts \\ 200) do
    if :sys.get_state(opts[:device_server]).entries[params["loginId"]].ready do
      :ok
    else
      assert attempts > 0
      Process.sleep(5)
      await_ready(params, opts, attempts - 1)
    end
  end

  defp authorize(params, opts, extra \\ %{}) do
    nonce =
      case ProviderManagement.device_challenge(params, opts) do
        {:ok, %{challengeNonce: nonce}} -> nonce || "not-ready"
        _ -> "binding-rejected"
      end

    completion = %{
      "completionId" => "completion-#{System.unique_integer([:positive])}",
      "challengeNonce" => nonce,
      "commit" => true
    }

    ProviderManagement.device_complete(Map.merge(params, Map.merge(completion, extra)), opts)
  end

  defp await_status(params, opts, expected, attempts \\ 200) do
    if expected in ["completed", "failed"] do
      assert {:ok, challenge} = ProviderManagement.device_challenge(params, opts)

      if is_binary(challenge.challengeNonce) do
        authorize(params, opts, %{"challengeNonce" => challenge.challengeNonce})
      end
    end

    assert {:ok, result} = ProviderManagement.device_poll(params, opts)

    if result.status == expected or attempts == 0 do
      assert result.status == expected
      result
    else
      Process.sleep(5)
      await_status(params, opts, expected, attempts - 1)
    end
  end
end
