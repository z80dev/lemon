defmodule LemonHoncho.ConfigTest do
  @moduledoc """
  The config is read on the way up, so the property under test throughout is
  that nothing an operator can type makes `load/0` raise or return a malformed
  struct — a bad value degrades to the default instead.
  """

  use ExUnit.Case, async: false

  alias LemonHoncho.Config

  @env_vars ~w(
    HONCHO_API_KEY
    HONCHO_BASE_URL
    HONCHO_ENVIRONMENT
    HONCHO_WORKSPACE
    HONCHO_PEER
    HONCHO_AI_PEER
    HONCHO_TIMEOUT_MS
    LEMON_HONCHO_PIN_USER_PEER
    LEMON_HONCHO_USER_PEER_ALIASES
    LEMON_HONCHO_RUNTIME_PEER_PREFIX
    LEMON_HONCHO_ENABLED
    LEMON_HONCHO_RECALL_MODE
    LEMON_HONCHO_SESSION_STRATEGY
    LEMON_HONCHO_CONTEXT_CADENCE
    LEMON_HONCHO_DIALECTIC_CADENCE
    LEMON_HONCHO_CONTEXT_TOKENS
    LEMON_HONCHO_DIALECTIC_MAX_CHARS
    LEMON_HONCHO_REASONING_LEVEL
    LEMON_HONCHO_OBSERVATION_MODE
    LEMON_HONCHO_SAVE_MESSAGES
    LEMON_HONCHO_INJECT_IN_SUBAGENTS
    LEMON_HONCHO_FIRST_TURN_WAIT_MS
    LEMON_HONCHO_MESSAGE_MAX_CHARS
    HOME
    LEMON_SECRETS_MASTER_KEY
  )

  @app_keys [
    :enabled,
    :api_key,
    :base_url,
    :environment,
    :workspace,
    :user_peer,
    :pin_user_peer,
    :user_peer_aliases,
    :runtime_peer_prefix,
    :ai_peer,
    :timeout_ms,
    :recall_mode,
    :session_strategy,
    :context_cadence,
    :dialectic_cadence,
    :context_tokens,
    :dialectic_max_chars,
    :reasoning_level,
    :observation_mode,
    :save_messages,
    :inject_in_subagents,
    :first_turn_wait_ms,
    :message_max_chars
  ]

  setup do
    home = Path.join(System.tmp_dir!(), "honcho_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})
    saved_secrets = Application.fetch_env(:lemon_core, LemonCore.Secrets)
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env])

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:lemon_honcho, &1))
    System.put_env("HOME", home)

    on_exit(fn ->
      Enum.each(saved_env, &restore_env/1)
      Enum.each(saved_app, &restore_app_env/1)

      case saved_secrets do
        {:ok, value} -> Application.put_env(:lemon_core, LemonCore.Secrets, value)
        :error -> Application.delete_env(:lemon_core, LemonCore.Secrets)
      end

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "gateway identity settings resolve from TOML, app env and environment", %{home: home} do
    path = Path.join(home, "gateway.toml")

    File.write!(path, """
    [honcho]
    pin_user_peer = true
    runtime_peer_prefix = "gateway_"
    user_peer_aliases = { telegram_123 = "alice", discord_456 = "alice" }
    """)

    toml = Config.load(config_path: path)
    assert toml.pin_user_peer
    assert toml.runtime_peer_prefix == "gateway_"
    assert toml.user_peer_aliases == %{"telegram_123" => "alice", "discord_456" => "alice"}

    Application.put_env(:lemon_honcho, :pin_user_peer, false)
    assert Config.load(config_path: path).pin_user_peer == false
    System.put_env("LEMON_HONCHO_PIN_USER_PEER", "true")
    System.put_env("LEMON_HONCHO_USER_PEER_ALIASES", ~s({"discord_789":"bob"}))
    System.put_env("LEMON_HONCHO_RUNTIME_PEER_PREFIX", "remote_")
    config = Config.load(config_path: path)
    assert config.pin_user_peer
    assert config.user_peer_aliases == %{"discord_789" => "bob"}
    assert config.runtime_peer_prefix == "remote_"

    System.put_env("LEMON_HONCHO_USER_PEER_ALIASES", ~s({"discord_789":"../bad"}))
    assert Config.load(config_path: path).user_peer_aliases == toml.user_peer_aliases
  end

  describe "load/0 defaults" do
    test "resolves every field to its documented default on a clean environment" do
      config = Config.load()

      assert config.enabled?
      assert config.api_key == nil
      assert config.base_url == nil
      assert config.environment == "production"
      assert config.workspace == "lemon"
      assert config.ai_peer == "lemon"
      assert config.timeout_ms == 30_000
      assert config.recall_mode == :hybrid
      assert config.session_strategy == :per_directory
      assert config.context_cadence == 1
      assert config.dialectic_cadence == 2
      assert config.context_tokens == nil
      assert config.dialectic_max_chars == 600
      assert config.reasoning_level == :low
      assert config.observation_mode == :directional
      assert config.save_messages?
      refute config.inject_in_subagents?
      assert config.first_turn_wait_ms == 3_000
      assert config.message_max_chars == 25_000
    end

    test "defaults the human peer to a sanitized $USER, never to an empty string" do
      config = Config.load()

      assert config.user_peer != ""
      assert config.user_peer =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "sanitizes an explicitly configured peer id" do
      System.put_env("HONCHO_PEER", "z80@ophy.xyz")

      assert Config.load().user_peer == "z80_ophy_xyz"
    end
  end

  describe "load/0 sources" do
    test "the environment wins over the application env" do
      Application.put_env(:lemon_honcho, :workspace, "from-app-env")
      System.put_env("HONCHO_WORKSPACE", "from-environment")

      assert Config.load().workspace == "from-environment"
    end

    test "the application env is used when the environment is unset" do
      Application.put_env(:lemon_honcho, :workspace, "from-app-env")
      Application.put_env(:lemon_honcho, :recall_mode, :tools)
      Application.put_env(:lemon_honcho, :timeout_ms, 1_234)

      config = Config.load()

      assert config.workspace == "from-app-env"
      assert config.recall_mode == :tools
      assert config.timeout_ms == 1_234
    end

    test "a blank environment value is treated as unset" do
      System.put_env("HONCHO_API_KEY", "   ")

      assert Config.load().api_key == nil
    end
  end

  describe "global [honcho] TOML" do
    test "loads persisted settings without a plaintext API key", %{home: home} do
      path = Path.join(home, "config.toml")

      File.write!(path, """
      [honcho]
      workspace = "migrated-workspace"
      user_peer = "alice"
      ai_peer = "hermes"
      base_url = "http://honcho.test:8000"
      environment = "local"
      timeout_ms = 1500
      recall_mode = "tools"
      session_strategy = "per-session"
      context_cadence = 3
      dialectic_cadence = 5
      context_tokens = 1200
      dialectic_max_chars = 900
      message_max_chars = 16000
      reasoning_level = "medium"
      observation_mode = "unified"
      save_messages = false
      api_key = "plaintext-must-not-be-used"
      """)

      config = Config.load(config_path: path)
      assert config.workspace == "migrated-workspace"
      assert config.user_peer == "alice"
      assert config.ai_peer == "hermes"
      assert config.environment == "local"
      assert config.timeout_ms == 1500
      assert config.recall_mode == :tools
      assert config.session_strategy == :per_session
      assert config.context_cadence == 3
      assert config.dialectic_cadence == 5
      assert config.context_tokens == 1200
      assert config.dialectic_max_chars == 900
      assert config.message_max_chars == 16000
      assert config.reasoning_level == :medium
      assert config.observation_mode == :unified
      refute config.save_messages?
      assert config.api_key == nil
      assert Config.configured?(config)
    end

    test "resolves an encrypted secret reference", %{home: home} do
      key = Base.encode64(:binary.copy(<<10>>, 32))
      System.put_env("LEMON_SECRETS_MASTER_KEY", key)
      name = "honcho_config_test_#{System.unique_integer([:positive])}"
      assert {:ok, _} = LemonCore.Secrets.set(name, "hk-config-test", key_providers: [:env])
      on_exit(fn -> LemonCore.Secrets.delete(name) end)
      path = Path.join(home, "config.toml")
      File.write!(path, "[honcho]\napi_key_secret = \"#{name}\"\n")

      assert Config.load(config_path: path).api_key == "hk-config-test"
      System.put_env("HONCHO_API_KEY", "hk-env")
      assert Config.load(config_path: path).api_key == "hk-env"
    end

    test "global config path and existing precedence are respected", %{home: home} do
      path = LemonCore.Config.global_path()
      assert String.starts_with?(path, home)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[honcho]\nworkspace = \"from-toml\"\nrecall_mode = \"tools\"\n")
      assert Config.load().workspace == "from-toml"
      Application.put_env(:lemon_honcho, :workspace, "from-app")
      assert Config.load().workspace == "from-app"
      System.put_env("HONCHO_WORKSPACE", "from-env")
      assert Config.load().workspace == "from-env"
    end

    test "bad TOML, invalid fields and unavailable secret references degrade safely", %{
      home: home
    } do
      path = Path.join(home, "config.toml")

      File.write!(
        path,
        "[honcho]\ncontext_cadence = -1\nrecall_mode = \"invalid\"\napi_key_secret = \"missing-honcho-key\"\n"
      )

      config = Config.load(config_path: path)
      assert config.context_cadence == 1
      assert config.recall_mode == :hybrid
      assert config.api_key == nil
      File.write!(path, "broken = [")
      assert Config.load(config_path: path).workspace == "lemon"
    end
  end

  describe "load/0 enums" do
    test "parses every recall mode" do
      for {raw, expected} <- [{"hybrid", :hybrid}, {"context", :context}, {"TOOLS", :tools}] do
        System.put_env("LEMON_HONCHO_RECALL_MODE", raw)

        assert Config.load().recall_mode == expected
      end
    end

    test "parses every session strategy, in dashed or underscored spelling" do
      cases = [
        {"per-session", :per_session},
        {"per_session", :per_session},
        {"per-directory", :per_directory},
        {"per-repo", :per_repo},
        {"global", :global}
      ]

      for {raw, expected} <- cases do
        System.put_env("LEMON_HONCHO_SESSION_STRATEGY", raw)

        assert Config.load().session_strategy == expected
      end
    end

    test "parses every reasoning level" do
      for level <- [:minimal, :low, :medium, :high, :max] do
        System.put_env("LEMON_HONCHO_REASONING_LEVEL", Atom.to_string(level))

        assert Config.load().reasoning_level == level
      end
    end

    test "parses both observation modes" do
      for mode <- [:directional, :unified] do
        System.put_env("LEMON_HONCHO_OBSERVATION_MODE", Atom.to_string(mode))

        assert Config.load().observation_mode == mode
      end
    end
  end

  describe "load/0 invalid values" do
    test "an unknown enum falls back to the default instead of raising" do
      System.put_env("LEMON_HONCHO_RECALL_MODE", "telepathy")
      System.put_env("LEMON_HONCHO_SESSION_STRATEGY", "per-mood")
      System.put_env("LEMON_HONCHO_REASONING_LEVEL", "maximum")
      System.put_env("LEMON_HONCHO_OBSERVATION_MODE", "sideways")

      config = Config.load()

      assert config.recall_mode == :hybrid
      assert config.session_strategy == :per_directory
      assert config.reasoning_level == :low
      assert config.observation_mode == :directional
    end

    test "an unparseable or out-of-range number falls back to the default" do
      System.put_env("HONCHO_TIMEOUT_MS", "soon")
      System.put_env("LEMON_HONCHO_CONTEXT_CADENCE", "0")
      System.put_env("LEMON_HONCHO_DIALECTIC_CADENCE", "-3")
      System.put_env("LEMON_HONCHO_MESSAGE_MAX_CHARS", "12_000")

      config = Config.load()

      assert config.timeout_ms == 30_000
      assert config.context_cadence == 1
      assert config.dialectic_cadence == 2
      assert config.message_max_chars == 25_000
    end

    test "a zero first-turn wait is honoured but a negative one is not" do
      System.put_env("LEMON_HONCHO_FIRST_TURN_WAIT_MS", "0")
      assert Config.load().first_turn_wait_ms == 0

      System.put_env("LEMON_HONCHO_FIRST_TURN_WAIT_MS", "-1")
      assert Config.load().first_turn_wait_ms == 3_000
    end

    test "an unrecognised boolean falls back to the default" do
      System.put_env("LEMON_HONCHO_SAVE_MESSAGES", "sometimes")
      System.put_env("LEMON_HONCHO_INJECT_IN_SUBAGENTS", "on")

      config = Config.load()

      assert config.save_messages?
      assert config.inject_in_subagents?
    end
  end

  describe "configured?/1" do
    test "a base URL alone is enough" do
      assert Config.configured?(%Config{base_url: "http://localhost:8000"})
    end

    test "an API key alone is enough" do
      assert Config.configured?(%Config{api_key: "sk-test"})
    end

    test "neither is not enough" do
      refute Config.configured?(%Config{})
      refute Config.configured?(%Config{api_key: "  ", base_url: ""})
    end

    test "the master switch overrides having credentials" do
      System.put_env("HONCHO_API_KEY", "sk-test")
      System.put_env("LEMON_HONCHO_ENABLED", "false")

      config = Config.load()

      refute config.enabled?
      refute Config.configured?(config)
    end

    test "credentials from the environment are enough on their own" do
      System.put_env("HONCHO_API_KEY", "sk-test")

      assert Config.configured?(Config.load())
    end

    # `HONCHO_API_KEY` is the vendor SDK's variable, not ours: anyone running
    # another Honcho client has it exported already. Keeping it sufficient is
    # the documented convenience above; this is the escape hatch that makes it
    # safe, and it is what `config/test.exs` uses to keep the suite off a real
    # workspace. It works because only `:api_key` is filled from that variable —
    # `:enabled` is resolved from `LEMON_HONCHO_ENABLED` and then the
    # application env, so with the former unset the latter decides.
    test "an application-env kill switch beats an exported vendor API key" do
      System.put_env("HONCHO_API_KEY", "sk-test")
      Application.put_env(:lemon_honcho, :enabled, false)

      config = Config.load()

      assert config.api_key == "sk-test"
      refute config.enabled?
      refute Config.configured?(config)
    end
  end

  describe "observation_flags/1" do
    test "directional has both peers observing both sides" do
      flags = Config.observation_flags(%Config{observation_mode: :directional})

      assert flags == %{
               user: %{observe_me: true, observe_others: true},
               ai: %{observe_me: true, observe_others: true}
             }
    end

    test "unified builds a single model of the user" do
      flags = Config.observation_flags(%Config{observation_mode: :unified})

      assert flags == %{
               user: %{observe_me: true, observe_others: false},
               ai: %{observe_me: false, observe_others: true}
             }
    end
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

  defp restore_app_env({key, :error}), do: Application.delete_env(:lemon_honcho, key)
  defp restore_app_env({key, {:ok, value}}), do: Application.put_env(:lemon_honcho, key, value)
end
