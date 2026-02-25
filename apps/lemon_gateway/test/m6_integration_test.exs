defmodule LemonGateway.M6IntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{BindingResolver, ChatState, Config, Store}
  alias LemonCore.ChatScope
  alias LemonCore.ResumeToken

  setup do
    test_toml_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-m6-integration-#{System.unique_integer([:positive, :monotonic])}"
      )

    original_home = System.get_env("HOME")
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    # Set up test directories
    File.rm_rf!(test_toml_dir)
    File.mkdir_p!(test_toml_dir)
    System.put_env("HOME", test_toml_dir)

    # Clean up any existing config
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
      File.rm_rf!(test_toml_dir)
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
    end)

    {:ok, %{test_toml_dir: test_toml_dir}}
  end

  describe "full M6 integration" do
    test "config loader parses TOML and populates Config", %{test_toml_dir: test_toml_dir} do
      project_root = Path.join(test_toml_dir, "project")
      File.mkdir_p!(project_root)

      toml_content = """
      [gateway]
      max_concurrent_runs = 8
      default_engine = "claude"

      [gateway.projects.myproject]
      root = "#{project_root}"
      default_engine = "codex"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123456
      project = "myproject"
      default_engine = "lemon"
      queue_mode = "followup"
      """

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")
      File.write!(toml_path, toml_content)
      Application.put_env(:lemon_gateway, :config_path, toml_path)

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify gateway config
      assert Config.get(:max_concurrent_runs) == 8
      assert Config.get(:default_engine) == "claude"

      # Verify projects loaded
      projects = Config.get_projects()
      assert map_size(projects) == 1
      assert projects["myproject"].root == project_root
      assert projects["myproject"].default_engine == "codex"

      # Verify bindings loaded
      bindings = Config.get_bindings()
      assert length(bindings) == 1
      [binding] = bindings
      assert binding.transport == :telegram
      assert binding.chat_id == 123_456
      assert binding.project == "myproject"
      assert binding.default_engine == "lemon"
      assert binding.queue_mode == :followup
    end

    test "binding resolver uses config for resolution", %{test_toml_dir: test_toml_dir} do
      project_root = Path.join(test_toml_dir, "project2")
      File.mkdir_p!(project_root)

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")

      File.write!(toml_path, """
      [gateway]
      default_engine = "global_default"

      [gateway.projects.myapp]
      root = "#{project_root}"
      default_engine = "project_engine"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 555
      project = "myapp"
      default_engine = "binding_engine"
      queue_mode = "collect"
      """)

      Application.put_env(:lemon_gateway, :config_path, toml_path)
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 555}

      # Check binding resolution
      binding = BindingResolver.resolve_binding(scope)
      assert binding.project == "myapp"
      assert binding.default_engine == "binding_engine"

      # Check engine resolution (binding takes precedence)
      engine = BindingResolver.resolve_engine(scope, nil, nil)
      assert engine == "binding_engine"

      # Check cwd resolution
      cwd = BindingResolver.resolve_cwd(scope)
      assert cwd == project_root

      # Check queue_mode resolution
      queue_mode = BindingResolver.resolve_queue_mode(scope)
      assert queue_mode == :collect
    end

    test "topic binding overrides chat binding", %{test_toml_dir: test_toml_dir} do
      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")

      File.write!(toml_path, """
      [gateway]
      default_engine = "global_default"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 777
      default_engine = "chat_engine"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 777
      topic_id = 123
      default_engine = "topic_engine"
      """)

      Application.put_env(:lemon_gateway, :config_path, toml_path)
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      chat_scope = %ChatScope{transport: :telegram, chat_id: 777}
      topic_scope = %ChatScope{transport: :telegram, chat_id: 777, topic_id: 123}

      # Chat scope uses chat binding engine
      assert BindingResolver.resolve_engine(chat_scope, nil, nil) == "chat_engine"

      # Topic scope uses topic binding engine
      assert BindingResolver.resolve_engine(topic_scope, nil, nil) == "topic_engine"
    end

    test "engine precedence cascade works correctly", %{test_toml_dir: test_toml_dir} do
      project_root = Path.join(test_toml_dir, "project3")
      File.mkdir_p!(project_root)

      config_dir = Path.join(test_toml_dir, ".lemon")
      File.mkdir_p!(config_dir)
      toml_path = Path.join(config_dir, "config.toml")

      File.write!(toml_path, """
      [gateway]
      default_engine = "global"

      [gateway.projects.proj]
      root = "#{project_root}"
      default_engine = "project"

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 888
      project = "proj"
      """)

      Application.put_env(:lemon_gateway, :config_path, toml_path)
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 888}

      # No hint, no resume: project default wins
      assert BindingResolver.resolve_engine(scope, nil, nil) == "project"

      # With hint: hint wins
      assert BindingResolver.resolve_engine(scope, "hint", nil) == "hint"

      # With resume: resume wins
      resume = %ResumeToken{engine: "resume", value: "token"}
      assert BindingResolver.resolve_engine(scope, "hint", resume) == "resume"
    end

    test "chat state persistence works", %{test_toml_dir: _test_toml_dir} do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      chat_id = System.unique_integer([:positive, :monotonic]) + System.system_time(:millisecond)
      scope = %ChatScope{transport: :telegram, chat_id: chat_id}

      # Initially no chat state
      assert Store.get_chat_state(scope) == nil

      # Store chat state (simulating what Run does after completion)
      chat_state = %ChatState{
        last_engine: "test_engine",
        last_resume_token: "test_token_123",
        updated_at: System.system_time(:millisecond)
      }

      Store.put_chat_state(scope, chat_state)
      Process.sleep(50)

      # Retrieve and verify
      retrieved = Store.get_chat_state(scope)
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
end
