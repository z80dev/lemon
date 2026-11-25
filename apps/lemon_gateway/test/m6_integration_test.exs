defmodule LemonGateway.M6IntegrationTest do
  use ExUnit.Case, async: false

  import LemonGateway.Test.AppIsolation

  alias LemonCore.{BindingResolver, ChatScope, ChatState, ChatStateStore, GatewayConfig}

  setup do
    test_toml_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-m6-integration-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(test_toml_dir) end)
    isolate_gateway([:config_path], system_env: ["HOME"])

    # Set up test directories
    File.mkdir_p!(test_toml_dir)
    System.put_env("HOME", test_toml_dir)

    # Clean up any existing config
    Application.delete_env(:lemon_core, :gateway_test_config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn -> LemonCore.ConfigCache.clear() end)

    {:ok, %{test_toml_dir: test_toml_dir}}
  end

  describe "full M6 integration" do
    test "the gateway reads [gateway] from the canonical config", %{test_toml_dir: test_toml_dir} do
      project_root = Path.join(test_toml_dir, "project")
      File.mkdir_p!(project_root)

      toml_content = """
      [gateway]
      max_concurrent_runs = 8

      [gateway.projects.myproject]
      root = "#{project_root}"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123456
      project = "myproject"
      queue_mode = "followup"
      """

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")
      File.write!(toml_path, toml_content)

      LemonCore.ConfigCache.clear()
      assert GatewayConfig.get(:max_concurrent_runs) == 8
      refute Map.has_key?(GatewayConfig.load(), :default_engine)
      refute Map.has_key?(GatewayConfig.load(), :engines)

      projects = GatewayConfig.get(:projects)
      assert map_size(projects) == 1
      assert GatewayConfig.fetch(projects["myproject"], :root, nil) == project_root

      binding =
        BindingResolver.resolve_binding(%ChatScope{transport: :telegram, chat_id: 123_456},
          bindings: GatewayConfig.get(:bindings)
        )

      assert binding.chat_id == 123_456
      assert binding.project == "myproject"
      assert binding.queue_mode == :followup
    end

    test "binding resolution reads the live config", %{test_toml_dir: test_toml_dir} do
      project_root = Path.join(test_toml_dir, "project2")
      File.mkdir_p!(project_root)

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")

      File.write!(toml_path, """
      [gateway]

      [gateway.projects.myapp]
      root = "#{project_root}"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 555
      project = "myapp"
      queue_mode = "collect"
      """)

      LemonCore.ConfigCache.clear()

      scope = %ChatScope{transport: :telegram, chat_id: 555}

      # Check binding resolution
      binding = BindingResolver.resolve_binding(scope, resolver_opts())
      assert binding.project == "myapp"

      # Check cwd resolution
      cwd = BindingResolver.resolve_cwd(scope, resolver_opts())
      assert cwd == project_root

      # Check queue_mode resolution
      queue_mode = BindingResolver.resolve_queue_mode(scope, resolver_opts())
      assert queue_mode == :collect
    end

    test "topic binding overrides chat binding", %{test_toml_dir: test_toml_dir} do
      chat_root = Path.join(test_toml_dir, "chat-project")
      topic_root = Path.join(test_toml_dir, "topic-project")
      File.mkdir_p!(chat_root)
      File.mkdir_p!(topic_root)

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")

      File.write!(toml_path, """
      [gateway.projects.chat]
      root = "#{chat_root}"

      [gateway.projects.topic]
      root = "#{topic_root}"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 777
      project = "chat"
      queue_mode = "collect"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 777
      topic_id = 123
      project = "topic"
      queue_mode = "interrupt"
      """)

      LemonCore.ConfigCache.clear()

      chat_scope = %ChatScope{transport: :telegram, chat_id: 777}
      topic_scope = %ChatScope{transport: :telegram, chat_id: 777, topic_id: 123}

      assert BindingResolver.resolve_binding(chat_scope, resolver_opts()).project == "chat"
      assert BindingResolver.resolve_binding(topic_scope, resolver_opts()).project == "topic"
      assert BindingResolver.resolve_cwd(topic_scope, resolver_opts()) == topic_root
      assert BindingResolver.resolve_queue_mode(topic_scope, resolver_opts()) == :interrupt
    end

    test "chat state persistence works" do
      chat_id = System.unique_integer([:positive, :monotonic]) + System.system_time(:millisecond)
      scope = %ChatScope{transport: :telegram, chat_id: chat_id}

      # Initially no chat state
      assert ChatStateStore.get(scope) == nil

      on_exit(fn -> ChatStateStore.delete(scope) end)

      chat_state = %ChatState{
        last_engine: "test_engine",
        last_resume_token: "test_token_123",
        updated_at: System.system_time(:millisecond)
      }

      :ok = ChatStateStore.put(scope, chat_state)

      # Retrieve and verify
      retrieved = ChatStateStore.get(scope)
      assert retrieved != nil

      # Get values from either struct or map
      get_val = fn map, key ->
        case map do
          %ChatState{} = cs -> Map.get(cs, key)
          m -> m[key] || Map.get(m, key)
        end
      end

      assert get_val.(retrieved, :last_engine) == "test_engine"
      assert get_val.(retrieved, :last_resume_token) == "test_token_123"
    end
  end

  defp resolver_opts do
    [
      bindings: GatewayConfig.get(:bindings),
      config_provider: fn -> GatewayConfig.get(:projects) end
    ]
  end
end
