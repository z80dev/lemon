defmodule LemonCli.RuntimeOwnedOnboardingTestClient do
  @moduledoc false
  def request(method, params, opts) do
    send(self(), {:control_plane_request, method, params, opts})

    case Process.get({:onboarding_reply, method}) do
      nil -> {:ok, %{}}
      reply -> reply
    end
  end
end

defmodule LemonCli.Onboarding.RuntimeOwnedOnboardingTest do
  @moduledoc """
  Provider onboarding beside a runtime that owns the store (#667): the default
  API-key save goes to the runtime's admin route; everything else refuses
  without writing. Offline: the control plane is a stub.
  """
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.{Provider, Runner}
  alias LemonCore.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    database = Path.join(tmp_dir, "owned.sqlite3")
    previous_home = System.get_env("HOME")
    System.put_env("HOME", home)
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    previous_secrets = Application.fetch_env(:lemon_core, :secrets)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, :secrets, key_providers: [:env])

    # The controller's provider identity already exists in the shared store.
    seed =
      start_supervised!(
        {Store,
         name: :onboarding_seed, backend: Store.SqliteBackend, backend_opts: [path: database]},
        id: :seed
      )

    :ok = Store.put(seed, :provider_management_identity, :controller, "controller:test-target")
    :ok = stop_supervised(:seed)

    lock = LemonCore.RuntimeOwner.lock_path(database)
    test = self()

    holder =
      spawn(fn ->
        LemonCore.FileLock.with_lock_path(lock, [], fn ->
          send(test, :runtime_lock_held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :runtime_lock_held

    store_config = Application.fetch_env!(:lemon_core, Store)
    override = Application.get_env(:lemon_core, :store_runtime_override, [])
    client = Application.fetch_env(:lemon_cli, :control_plane_client)

    restart_store(
      [backend: Store.SqliteBackend, backend_opts: [path: database], defer_to_runtime: true],
      []
    )

    Application.put_env(
      :lemon_cli,
      :control_plane_client,
      LemonCli.RuntimeOwnedOnboardingTestClient
    )

    on_exit(fn ->
      case client do
        {:ok, module} -> Application.put_env(:lemon_cli, :control_plane_client, module)
        :error -> Application.delete_env(:lemon_cli, :control_plane_client)
      end

      restart_store(store_config, override)
      send(holder, :release)

      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")

      if previous_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", previous_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      case previous_secrets do
        {:ok, config} -> Application.put_env(:lemon_core, :secrets, config)
        :error -> Application.delete_env(:lemon_core, :secrets)
      end
    end)

    assert {:error, :runtime_owned} = Store.write_access()
    %{config_path: LemonCore.Config.global_path()}
  end

  test "the default API-key save goes to the runtime's admin route and nothing local", c do
    assert :ok = run(["--token", "sk-runtime-route", "--no-set-default"])

    assert_received {:control_plane_request, "providers.management.api_key.set", params, _}

    assert params == %{
             "targetId" => "controller:test-target",
             "providerId" => "testprov",
             "value" => "sk-runtime-route"
           }

    refute_received {:control_plane_request, "providers.management.default.set", _, _}
    assert_received {:info, "Secret: managed by the running Lemon runtime"}
    refute File.exists?(c.config_path)

    assert {:ok, nil} =
             Store.fetch(LemonCore.Secrets.table(), {"default", "llm_testprov_api_key"})
  end

  test "definite refusals and unconfirmed saves are told apart and never retried" do
    cases = [
      {{:error, {:control_plane_unavailable, :econnrefused}}, "did not answer"},
      {{:error, {:control_plane, %{"code" => "FORBIDDEN"}}},
       "refused to save the API key (FORBIDDEN)"},
      {{:error,
        {:control_plane,
         %{"code" => "CONFLICT", "details" => %{"mutationMayHaveApplied" => false}}}},
       "refused to save the API key (CONFLICT)"},
      {{:error,
        {:control_plane,
         %{"code" => "UNAVAILABLE", "details" => %{"mutationMayHaveApplied" => true}}}},
       "may or may not have been applied"},
      {{:error, :control_plane_timeout}, "may or may not have been applied"}
    ]

    for {reply, expected} <- cases do
      Process.put({:onboarding_reply, "providers.management.api_key.set"}, reply)
      message = run_error(["--token", "sk-never-shown", "--no-set-default"])
      assert message =~ expected, "#{inspect(reply)}: #{message}"
      refute message =~ "sk-never-shown"
      assert_received {:control_plane_request, "providers.management.api_key.set", _, _}
      refute_received {:control_plane_request, _, _, _}
    end
  end

  test "a custom secret name or config path refuses without writing or calling the runtime", c do
    for argv <- [
          ["--token", "sk-x", "--no-set-default", "--secret-name", "custom_name"],
          ["--token", "sk-x", "--no-set-default", "--config-path", c.config_path <> ".other"]
        ] do
      assert run_error(argv) =~ "Only the default API-key setup can be sent to it"
      refute_received {:control_plane_request, _, _, _}
    end

    refute File.exists?(c.config_path)
  end

  defp spec do
    %Provider{
      id: "testprov",
      display_name: "Test Provider",
      provider_table: "providers.testprov",
      default_secret_name: "llm_testprov_api_key",
      api_key_secret_provider: "onboarding_testprov",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      auth_source_by_mode: %{api_key: "api_key"},
      secret_config_key_by_mode: %{api_key: "api_key_secret"}
    }
  end

  defp io do
    test = self()

    %{
      info: fn message -> send(test, {:info, message}) end,
      error: fn message -> send(test, {:error, message}) end,
      prompt: fn _message -> "" end,
      secret: fn _message -> "" end
    }
  end

  defp run(argv), do: Runner.run(argv, spec(), io: io())

  defp run_error(argv) do
    run(argv)
    flunk("expected #{inspect(argv)} to fail")
  rescue
    error -> Exception.message(error)
  end

  defp restart_store(config, override) do
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)
    Application.put_env(:lemon_core, Store, config)
    Application.put_env(:lemon_core, :store_runtime_override, override)
    {:ok, _pid} = Supervisor.restart_child(LemonCore.Supervisor, Store)
  end
end
