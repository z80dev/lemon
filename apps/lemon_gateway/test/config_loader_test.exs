defmodule LemonGateway.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{Binding, ConfigLoader, Project}

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
    enable_telegram = true

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
    assert config.enable_telegram == true
    assert config.queue.mode == :collect
    assert config.queue.cap == 10
    assert config.queue.drop == :oldest

    assert %{"demo" => %Project{root: "/tmp/demo"}} = config.projects
    assert [%Binding{transport: :telegram, chat_id: 123, project: "demo"}] = config.bindings

    assert %{lemon: %{cli_path: "lemon", enabled: true}} = config.engines
  end
end
