defmodule LemonControlPlane.Methods.StatusTest do
  # Stops lemon_channels in one test, so it cannot share the VM with async tests.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Health, Status}

  defmodule Channel do
    use Agent
    def id, do: "status-test"
    def meta, do: %{}
    def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  setup do
    keys = ~w(RELEASE_NAME RELEASE_VSN LEMON_GIT_SHA LEMON_RELEASE_CHANNEL LEMON_LAUNCHER)
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "health returns public runtime summary" do
    assert {:ok, result} = Health.handle(%{}, %{})

    assert result["ok"] == true
    assert is_integer(result["uptime_ms"])
    assert is_float(result["memory_mb"])
    assert is_integer(result["schedulers"])
    assert result["summary"]["action"] == "health"
    assert result["summary"]["ok"] == true
    assert result["summary"]["uptimeMs"] == result["uptime_ms"]
    assert result["summary"]["memoryMb"] == result["memory_mb"]
    assert result["summary"]["schedulerCount"] == result["schedulers"]
    assert result["summary"]["cleanup"]["includesRawProcessState"] == false
    assert result["summary"]["cleanup"]["includesCredentialValues"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
  end

  test "returns BEAM runtime capacity counters" do
    assert {:ok, result} = Status.handle(%{}, %{})

    assert result["server"]["version"] == LemonControlPlane.server_version()
    assert is_integer(result["server"]["beam"]["processCount"])
    assert result["server"]["beam"]["processCount"] > 0
    assert result["server"]["beam"]["processLimit"] >= result["server"]["beam"]["processCount"]
    assert is_integer(result["server"]["beam"]["portCount"])
    assert result["server"]["beam"]["portLimit"] >= result["server"]["beam"]["portCount"]
    assert is_integer(result["server"]["beam"]["atomCount"])
    assert result["server"]["beam"]["atomLimit"] >= result["server"]["beam"]["atomCount"]
    assert is_integer(result["server"]["beam"]["runQueue"])
    assert result["summary"]["action"] == "status"
    assert result["summary"]["version"] == result["server"]["version"]
    assert result["summary"]["uptimeMs"] == result["server"]["uptime_ms"]
    assert result["summary"]["memoryMb"] == result["server"]["memory_mb"]
    assert result["summary"]["schedulerCount"] == result["server"]["schedulers"]
    assert result["summary"]["processCount"] == result["server"]["beam"]["processCount"]
    assert result["summary"]["processLimit"] == result["server"]["beam"]["processLimit"]
    assert result["summary"]["portCount"] == result["server"]["beam"]["portCount"]
    assert result["summary"]["portLimit"] == result["server"]["beam"]["portLimit"]
    assert result["summary"]["atomCount"] == result["server"]["beam"]["atomCount"]
    assert result["summary"]["atomLimit"] == result["server"]["beam"]["atomLimit"]
    assert result["summary"]["runQueue"] == result["server"]["beam"]["runQueue"]
    assert result["summary"]["connectionCount"] == result["connections"]["active"]
    assert result["summary"]["activeRunCount"] == result["runs"]["active"]
    assert result["summary"]["configuredChannelCount"] == length(result["channels"]["configured"])
    assert result["summary"]["connectedChannelCount"] == length(result["channels"]["connected"])
    assert result["summary"]["installedSkillCount"] == result["skills"]["installed"]
    assert result["summary"]["enabledSkillCount"] == result["skills"]["enabled"]
    assert result["summary"]["cleanup"]["includesRawProcessState"] == false
    assert result["summary"]["cleanup"]["includesChannelCredentials"] == false
    assert result["summary"]["cleanup"]["includesSkillSources"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
  end

  test "reports the umbrella CalVer in status and hello, with env-only build metadata" do
    assert {:ok, source} = File.read(Path.expand("../../../../../mix.exs", __DIR__))
    [_, version] = Regex.run(~r/version:\s*"([^"]+)"/, source)
    assert LemonControlPlane.server_version() == version
    System.put_env("LEMON_GIT_SHA", "sample-build-commit")
    assert {:ok, result} = Status.handle(%{}, %{})

    assert result["server"]["build"] == %{
             "runtimeMode" => "source-dev",
             "channel" => nil,
             "commit" => "sample-build-commit"
           }

    hello = LemonControlPlane.Protocol.Frames.encode_hello_ok(%{}) |> Jason.decode!()
    assert hello["server"]["version"] == version
  end

  test "packaged release metadata wins over OTP package versions" do
    System.put_env("RELEASE_NAME", "lemon_runtime_full")
    System.put_env("RELEASE_VSN", "2026.10.15-preview")
    System.put_env("LEMON_RELEASE_CHANNEL", "preview")
    assert {:ok, result} = Status.handle(%{}, %{})
    assert result["server"]["version"] == "2026.10.15-preview"
    assert result["summary"]["version"] == "2026.10.15-preview"

    assert result["server"]["build"] == %{
             "runtimeMode" => "release-runtime",
             "channel" => "preview",
             "commit" => nil
           }
  end

  test "projects configured providers, missing credentials, keyless endpoints and defaults offline" do
    config = %{
      agent: %{default_provider: "status-missing", default_model: "example-model"},
      providers: %{
        "status-missing" => %{api_key_secret: "nonexistent-status-secret"},
        "status-present" => %{api_key: "never-include-this-test-key"},
        "status-local" => %{auth: "none", base_url: "http://127.0.0.1:49999/v1"}
      }
    }

    providers = LemonControlPlane.ProviderStatus.snapshot(config)
    missing = Enum.find(providers, &(&1["id"] == "status-missing"))

    assert missing == %{
             "id" => "status-missing",
             "configured" => true,
             "credential" => "missing",
             "default" => true,
             "lastError" => nil
           }

    assert Enum.find(providers, &(&1["id"] == "status-present"))["credential"] == "present"
    assert Enum.find(providers, &(&1["id"] == "status-local"))["credential"] == "not_required"
    refute Jason.encode!(providers) =~ "never-include"
    refute Jason.encode!(providers) =~ "49999"

    assert {:ok, result} = Status.handle(%{}, %{})
    assert is_list(result["providers"])
    assert result["summary"]["providerCount"] == length(result["providers"])

    assert result["summary"]["providersMissingCredentials"] ==
             Enum.count(result["providers"], &(&1["credential"] == "missing"))
  end

  test "channel health retains a timestamped sanitized error and clears it on recovery" do
    :ok = LemonChannels.Registry.register(Channel)
    on_exit(fn -> LemonChannels.Registry.unregister(Channel.id()) end)
    assert {:ok, configured} = Status.handle(%{}, %{})

    assert %{"state" => "configured", "lastError" => nil} =
             Enum.find(configured["channels"]["details"], &(&1["id"] == Channel.id()))

    before = System.system_time(:millisecond)

    LemonChannels.Registry.record_status(
      Channel.id(),
      {:error, {:http_error, 401, "/private/token=secret"}}
    )

    assert {:ok, failed} = Status.handle(%{}, %{})
    detail = Enum.find(failed["channels"]["details"], &(&1["id"] == Channel.id()))
    assert detail["state"] == "error"
    assert detail["lastError"]["atMs"] >= before
    assert String.length(detail["lastError"]["message"]) <= 256
    refute Jason.encode!(detail) =~ "/private"
    refute Jason.encode!(detail) =~ "token="
    assert failed["summary"]["channelErrorCount"] >= 1

    start_supervised!(Channel)
    LemonChannels.Registry.record_status(Channel.id(), :connected)
    assert {:ok, recovered} = Status.handle(%{}, %{})

    assert %{"state" => "connected", "lastError" => nil} =
             Enum.find(recovered["channels"]["details"], &(&1["id"] == Channel.id()))
  end

  test "lifecycle availability distinguishes managed and unmanaged runtimes" do
    assert {:ok, result} = Status.handle(%{}, %{})
    assert %{"restart" => false, "stop" => true, "reason" => reason} = result["lifecycle"]
    assert reason =~ "LEMON_LAUNCHER"
    System.put_env("LEMON_LAUNCHER", "/test/lemon")
    assert {:ok, managed} = Status.handle(%{}, %{})
    assert managed["lifecycle"] == %{"restart" => true, "stop" => true, "reason" => nil}
  end

  test "a stopped channels app reports no channels instead of failing the request" do
    :ok = Application.stop(:lemon_channels)
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:lemon_channels) end)

    assert {:ok, result} = Status.handle(%{}, %{})
    assert result["channels"] == %{"configured" => [], "connected" => [], "details" => []}
    assert result["summary"]["configuredChannelCount"] == 0
  end

  test "has correct method name and scopes" do
    assert Health.name() == "health"
    assert Health.scopes() == []
    assert Status.name() == "status"
    assert Status.scopes() == [:read]
  end
end
