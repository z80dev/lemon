defmodule LemonGateway.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{Binding, ConfigLoader, Project}
  alias LemonGateway.Transports.Email.Outbound

  setup do
    original_home = System.get_env("HOME")
    original_override = Application.get_env(:lemon_gateway, LemonGateway.Config)
    original_config_path = Application.get_env(:lemon_gateway, :config_path)

    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_gateway_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    System.put_env("HOME", tmp_dir)
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if is_nil(original_override) do
        Application.delete_env(:lemon_gateway, LemonGateway.Config)
      else
        Application.put_env(:lemon_gateway, LemonGateway.Config, original_override)
      end

      if is_nil(original_config_path) do
        Application.delete_env(:lemon_gateway, :config_path)
      else
        Application.put_env(:lemon_gateway, :config_path, original_config_path)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{home: tmp_dir}
  end

  test "loads gateway config from canonical TOML", %{home: home} do
    config_dir = Path.join(home, ".lemon")
    File.mkdir_p!(config_dir)

    File.write!(Path.join(config_dir, "config.toml"), """
    [gateway]
    max_concurrent_runs = 3
    default_engine = "lemon"
    default_cwd = "/tmp/lemon-home"
    enable_telegram = true

    [gateway.sms]
    webhook_port = 8786

    [gateway.queue]
    mode = "collect"
    cap = 10
    drop = "oldest"

    [gateway.projects.demo]
    root = "/tmp/demo"
    default_engine = "lemon"

    [[gateway.bindings]]
    transport = "telegram"
    chat_id = 123
    topic_id = 0
    project = "demo"
    default_engine = "lemon"
    queue_mode = "collect"

    [gateway.engines.lemon]
    cli_path = "lemon"
    enabled = true
    """)

    config = ConfigLoader.load()

    assert config.max_concurrent_runs == 3
    assert config.default_engine == "lemon"
    assert config.default_cwd == "/tmp/lemon-home"
    assert config.enable_telegram == true
    assert config.sms.webhook_port == 8786
    assert config.queue.mode == :collect
    assert config.queue.cap == 10
    assert config.queue.drop == :oldest

    assert %{"demo" => %Project{root: "/tmp/demo"}} = config.projects
    assert [%Binding{transport: :telegram, chat_id: 123, project: "demo"}] = config.bindings

    assert %{lemon: %{cli_path: "lemon", enabled: true}} = config.engines
  end

  test "parses telegram files auto-send settings from override config" do
    Application.put_env(
      :lemon_gateway,
      LemonGateway.Config,
      %{
        "telegram" => %{
          "compaction" => %{
            "enabled" => true,
            "context_window_tokens" => 123_000,
            "reserve_tokens" => 12_000,
            "trigger_ratio" => 0.88
          },
          "files" => %{
            "enabled" => true,
            "auto_send_generated_images" => true,
            "auto_send_generated_max_files" => 4,
            "outbound_send_delay_ms" => 800
          }
        }
      }
    )

    config = ConfigLoader.load()

    assert config.telegram.compaction.enabled == true
    assert config.telegram.compaction.context_window_tokens == 123_000
    assert config.telegram.compaction.reserve_tokens == 12_000
    assert config.telegram.compaction.trigger_ratio == 0.88
    assert config.telegram.files.enabled == true
    assert config.telegram.files.auto_send_generated_images == true
    assert config.telegram.files.auto_send_generated_max_files == 4
    assert config.telegram.files.outbound_send_delay_ms == 800
  end

  test "parses farcaster hardening options from override config" do
    Application.put_env(
      :lemon_gateway,
      LemonGateway.Config,
      %{
        "farcaster" => %{
          "frame_enabled" => true,
          "port" => 4044,
          "bind" => "127.0.0.1",
          "action_path" => "/frames/farcaster/actions",
          "frame_base_url" => "https://example.test",
          "image_url" => "https://example.test/frame.png",
          "input_label" => "Ask Lemon",
          "button_1" => "Run",
          "button_2" => "Reset",
          "account_id" => "bot",
          "state_secret" => "test-secret",
          "verify_trusted_data" => true,
          "hub_validate_url" => "https://hub.example.test/validate"
        }
      }
    )

    config = ConfigLoader.load()

    assert config.farcaster.frame_enabled == true
    assert config.farcaster.port == 4044
    assert config.farcaster.bind == "127.0.0.1"
    assert config.farcaster.action_path == "/frames/farcaster/actions"
    assert config.farcaster.frame_base_url == "https://example.test"
    assert config.farcaster.image_url == "https://example.test/frame.png"
    assert config.farcaster.input_label == "Ask Lemon"
    assert config.farcaster.button_1 == "Run"
    assert config.farcaster.button_2 == "Reset"
    assert config.farcaster.account_id == "bot"
    assert config.farcaster.state_secret == "test-secret"
    assert config.farcaster.verify_trusted_data == true
    assert config.farcaster.hub_validate_url == "https://hub.example.test/validate"
  end

  test "defaults farcaster trusted-data verification to true when key is omitted" do
    Application.put_env(
      :lemon_gateway,
      LemonGateway.Config,
      %{
        "farcaster" => %{
          "frame_enabled" => true
        }
      }
    )

    config = ConfigLoader.load()

    assert config.farcaster.verify_trusted_data == true
  end

  test "parses email outbound config and normalizes smtp options from nested values" do
    Application.put_env(
      :lemon_gateway,
      LemonGateway.Config,
      %{
        "enable_email" => true,
        "email" => %{
          "smtp_relay" => "flat-relay.example.test",
          "smtp_port" => "2525",
          "smtp_ssl" => true,
          "smtp_tls" => "always",
          "smtp_auth" => "never",
          "smtp_username" => "flat-user",
          "smtp_password" => "flat-pass",
          "outbound" => %{
            "relay" => " nested-relay.example.test ",
            "port" => "587",
            "ssl" => false,
            "tls" => "never",
            "auth" => "if_available",
            "username" => " nested-user ",
            "password" => " nested-pass ",
            "hostname" => " mail.example.test ",
            "tls_versions" => ["tlsv1.2", "tlsv1.3"]
          }
        }
      }
    )

    config = ConfigLoader.load()

    assert config.enable_email == true
    assert config.email.outbound.relay == " nested-relay.example.test "
    assert config.email.smtp_relay == "flat-relay.example.test"

    assert {:ok, smtp_opts} = Outbound.smtp_options(config.email)
    assert Keyword.fetch!(smtp_opts, :relay) == "nested-relay.example.test"
    assert Keyword.fetch!(smtp_opts, :port) == 587
    assert Keyword.fetch!(smtp_opts, :ssl) == false
    assert Keyword.fetch!(smtp_opts, :tls) == :never
    assert Keyword.fetch!(smtp_opts, :auth) == :if_available
    assert Keyword.fetch!(smtp_opts, :username) == "nested-user"
    assert Keyword.fetch!(smtp_opts, :password) == "nested-pass"
    assert Keyword.fetch!(smtp_opts, :hostname) == "mail.example.test"
    assert {:tls_options, [versions: [:"tlsv1.2", :"tlsv1.3"]]} in smtp_opts
  end
end
