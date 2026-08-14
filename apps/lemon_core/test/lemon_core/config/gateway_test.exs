defmodule LemonCore.Config.GatewayTest.StubChannel do
  @behaviour LemonCore.Config.Gateway.Channel

  @impl true
  def id, do: :stub

  @impl true
  def resolve(section), do: %{resolved: true, raw: section}

  @impl true
  def enabled?(configured), do: configured

  @impl true
  def validate(section, errors) do
    if Map.get(section, :resolved), do: errors, else: ["gateway.stub: invalid" | errors]
  end
end

defmodule LemonCore.Config.GatewayTest do
  @moduledoc """
  Tests for the Config.Gateway module.

  Per-platform sections are owned by the modules registered under
  `config :lemon_core, :gateway_channels`; what any platform's section means
  lives with that platform (in lemon_channels' adapter config tests). These
  tests prove the generic routing mechanism with a stub channel only.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Gateway

  setup do
    # Register a stub channel so the per-platform routing mechanism is
    # exercised without naming a real platform. Other suites may have booted
    # real channel modules, so the registry is replaced for each test and
    # restored afterwards.
    previous = Application.get_env(:lemon_core, :gateway_channels)
    Application.put_env(:lemon_core, :gateway_channels, [__MODULE__.StubChannel])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_core, :gateway_channels),
        else: Application.put_env(:lemon_core, :gateway_channels, previous)
    end)

    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      [
        "LEMON_GATEWAY_MAX_CONCURRENT_RUNS",
        "LEMON_GATEWAY_DEFAULT_ENGINE",
        "LEMON_GATEWAY_DEFAULT_CWD",
        "LEMON_GATEWAY_AUTO_RESUME",
        "LEMON_GATEWAY_REQUIRE_ENGINE_LOCK",
        "LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS"
      ]
      |> Enum.each(&System.delete_env/1)

      # Restore original values
      original_env
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "uses defaults when no settings provided" do
      config = Gateway.resolve(%{})

      assert config.max_concurrent_runs == 2
      assert config.default_engine == "lemon"
      assert config.default_cwd == nil
      assert config.auto_resume == false
      assert config.enabled_channels[:stub] == false
      assert config.channels[:stub] == %{resolved: true, raw: %{}}
      assert config.require_engine_lock == true
      assert config.engine_lock_timeout_ms == 60_000
      assert config.projects == %{}
      assert config.bindings == []
      assert config.sms == %{}
      assert config.engines == %{}
    end

    test "uses settings from config map" do
      settings = %{
        "gateway" => %{
          "max_concurrent_runs" => 5,
          "default_engine" => "custom",
          "default_cwd" => "~/projects",
          "auto_resume" => true,
          "enable_stub" => true
        }
      }

      config = Gateway.resolve(settings)

      assert config.max_concurrent_runs == 5
      assert config.default_engine == "custom"
      assert config.default_cwd == "~/projects"
      assert config.auto_resume == true
      assert config.enabled_channels[:stub] == true
    end

    test "environment variables override settings" do
      System.put_env("LEMON_GATEWAY_MAX_CONCURRENT_RUNS", "10")
      System.put_env("LEMON_GATEWAY_DEFAULT_ENGINE", "custom")
      System.put_env("LEMON_GATEWAY_DEFAULT_CWD", "/workspace")
      System.put_env("LEMON_GATEWAY_AUTO_RESUME", "true")
      System.put_env("LEMON_GATEWAY_REQUIRE_ENGINE_LOCK", "false")
      System.put_env("LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS", "120000")

      settings = %{
        "gateway" => %{
          "max_concurrent_runs" => 2,
          "default_engine" => "lemon",
          "default_cwd" => "~/home",
          "auto_resume" => false,
          "enable_stub" => false,
          "require_engine_lock" => true,
          "engine_lock_timeout_ms" => 60_000
        }
      }

      config = Gateway.resolve(settings)

      assert config.max_concurrent_runs == 10
      assert config.default_engine == "custom"
      assert config.default_cwd == "/workspace"
      assert config.auto_resume == true
      assert config.enabled_channels[:stub] == false
      assert config.require_engine_lock == false
      assert config.engine_lock_timeout_ms == 120_000
    end
  end

  describe "default_cwd configuration" do
    test "trims whitespace from default_cwd" do
      settings = %{
        "gateway" => %{
          "default_cwd" => "  ~/workspace  "
        }
      }

      config = Gateway.resolve(settings)

      assert config.default_cwd == "~/workspace"
    end
  end

  describe "bindings configuration" do
    test "parses bindings from config" do
      settings = %{
        "gateway" => %{
          "bindings" => [
            %{
              "transport" => "demo",
              "chat_id" => 123_456_789,
              "agent_id" => "default"
            },
            %{
              "transport" => "demo",
              "chat_id" => 987_654_321,
              "agent_id" => "assistant"
            }
          ]
        }
      }

      config = Gateway.resolve(settings)

      assert length(config.bindings) == 2

      [first, second] = config.bindings
      assert first.transport == :demo
      assert first.chat_id == 123_456_789
      assert first.agent_id == "default"

      assert second.transport == :demo
      assert second.chat_id == 987_654_321
      assert second.agent_id == "assistant"
    end

    test "returns empty list when no bindings" do
      config = Gateway.resolve(%{})
      assert config.bindings == []
    end
  end

  describe "queue configuration" do
    test "uses default queue settings" do
      config = Gateway.resolve(%{})

      assert config.queue.mode == nil
      assert config.queue.cap == nil
      assert config.queue.drop == nil
    end

    test "uses queue settings from config" do
      settings = %{
        "gateway" => %{
          "queue" => %{
            "mode" => "fifo",
            "cap" => 100,
            "drop" => "oldest"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.queue.mode == "fifo"
      assert config.queue.cap == 100
      assert config.queue.drop == "oldest"
    end
  end

  describe "channel configuration" do
    test "a registered channel's resolve/1 output lands in config.channels" do
      settings = %{
        "gateway" => %{
          "stub" => %{"foo" => "bar"}
        }
      }

      config = Gateway.resolve(settings)

      assert config.channels[:stub] == %{resolved: true, raw: %{"foo" => "bar"}}
    end

    test "enabled?/1 receives the enable_stub TOML value and its result lands in enabled_channels" do
      config = Gateway.resolve(%{"gateway" => %{"enable_stub" => true}})
      assert config.enabled_channels[:stub] == true

      config = Gateway.resolve(%{"gateway" => %{"enable_stub" => false}})
      assert config.enabled_channels[:stub] == false

      config = Gateway.resolve(%{})
      assert config.enabled_channels[:stub] == false
    end

    test "an unregistered build yields empty channels and enabled_channels" do
      Application.put_env(:lemon_core, :gateway_channels, [])

      on_exit(fn ->
        Application.put_env(:lemon_core, :gateway_channels, [__MODULE__.StubChannel])
      end)

      config = Gateway.resolve(%{"gateway" => %{"stub" => %{"foo" => "bar"}}})

      assert config.channels == %{}
      assert config.enabled_channels == %{}
    end
  end

  describe "projects configuration" do
    test "uses projects from config" do
      settings = %{
        "gateway" => %{
          "projects" => %{
            "project1" => %{"cwd" => "~/project1"},
            "project2" => %{"cwd" => "~/project2"}
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.projects["project1"]["cwd"] == "~/project1"
      assert config.projects["project2"]["cwd"] == "~/project2"
    end

    test "returns empty map when no projects" do
      config = Gateway.resolve(%{})
      assert config.projects == %{}
    end
  end

  describe "sms configuration" do
    test "uses sms from config" do
      settings = %{
        "gateway" => %{
          "sms" => %{
            "provider" => "twilio",
            "account_sid" => "AC123"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.sms["provider"] == "twilio"
      assert config.sms["account_sid"] == "AC123"
    end

    test "returns empty map when no sms config" do
      config = Gateway.resolve(%{})
      assert config.sms == %{}
    end
  end

  describe "engines configuration" do
    test "uses engines from config" do
      settings = %{
        "gateway" => %{
          "engines" => %{
            "lemon" => %{"enabled" => true},
            "custom" => %{"enabled" => false}
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.engines["lemon"]["enabled"] == true
      assert config.engines["custom"]["enabled"] == false
    end

    test "returns empty map when no engines config" do
      config = Gateway.resolve(%{})
      assert config.engines == %{}
    end
  end

  describe "defaults/0" do
    test "returns the default gateway configuration" do
      defaults = Gateway.defaults()

      assert defaults["max_concurrent_runs"] == 2
      assert defaults["default_engine"] == "lemon"
      assert defaults["default_cwd"] == nil
      assert defaults["auto_resume"] == false
      assert defaults["enable_stub"] == false
      assert defaults["stub"] == %{}
      assert defaults["require_engine_lock"] == true
      assert defaults["engine_lock_timeout_ms"] == 60_000
      assert defaults["projects"] == %{}
      assert defaults["bindings"] == []
      assert defaults["sms"] == %{}
      assert defaults["engines"] == %{}
    end

    test "contains no platform keys when no channel is registered" do
      Application.put_env(:lemon_core, :gateway_channels, [])

      on_exit(fn ->
        Application.put_env(:lemon_core, :gateway_channels, [__MODULE__.StubChannel])
      end)

      defaults = Gateway.defaults()

      refute Map.has_key?(defaults, "enable_stub")
      refute Map.has_key?(defaults, "stub")
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = Gateway.resolve(%{})

      assert %Gateway{} = config
      assert is_integer(config.max_concurrent_runs)
      assert is_binary(config.default_engine)
      assert is_boolean(config.auto_resume)
      assert is_map(config.enabled_channels)
      assert is_boolean(config.require_engine_lock)
      assert is_integer(config.engine_lock_timeout_ms)
      assert is_map(config.projects)
      assert is_list(config.bindings)
      assert is_map(config.sms)
      assert is_map(config.queue)
      assert is_map(config.channels)
      assert is_map(config.engines)
    end
  end
end
