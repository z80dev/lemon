defmodule LemonGateway.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{Binding, ConfigLoader, Project}

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Clean up any existing config before each test
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
    end)

    :ok
  end

  # ============================================================================
  # TOML Parsing - Valid Files
  # ============================================================================

  describe "load/0 with valid TOML file" do
    @tag :tmp_dir
    test "parses minimal gateway config", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:default_engine] == "claude"
      assert result[:projects] == %{}
      assert result[:bindings] == []
    end

    @tag :tmp_dir
    test "parses gateway config with all settings", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "codex"
      max_concurrent_runs = 5
      timeout_ms = 30000
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:default_engine] == "codex"
      assert result[:max_concurrent_runs] == 5
      assert result[:timeout_ms] == 30000
    end

    @tag :tmp_dir
    test "parses projects with required fields", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects.myapp]
      root = "#{project_root}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert Map.has_key?(result[:projects], "myapp")
      project = result[:projects]["myapp"]
      assert %Project{} = project
      assert project.id == "myapp"
      assert project.root == project_root
      assert project.default_engine == nil
    end

    @tag :tmp_dir
    test "parses projects with default_engine", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects.myapp]
      root = "#{project_root}"
      default_engine = "lemon"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      project = result[:projects]["myapp"]
      assert project.default_engine == "lemon"
    end

    @tag :tmp_dir
    test "parses multiple projects", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project1_root = Path.join(tmp_dir, "project1")
      project2_root = Path.join(tmp_dir, "project2")
      File.mkdir_p!(project1_root)
      File.mkdir_p!(project2_root)

      File.write!(config_path, """
      [projects.app1]
      root = "#{project1_root}"
      default_engine = "claude"

      [projects.app2]
      root = "#{project2_root}"
      default_engine = "codex"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert map_size(result[:projects]) == 2
      assert result[:projects]["app1"].root == project1_root
      assert result[:projects]["app2"].root == project2_root
      assert result[:projects]["app1"].default_engine == "claude"
      assert result[:projects]["app2"].default_engine == "codex"
    end

    @tag :tmp_dir
    test "parses bindings with transport and chat_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      project = "myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert length(result[:bindings]) == 1
      binding = hd(result[:bindings])
      assert %Binding{} = binding
      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.project == "myapp"
    end

    @tag :tmp_dir
    test "parses bindings with topic_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 999
      project = "myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.topic_id == 999
    end

    @tag :tmp_dir
    test "parses bindings with default_engine", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      default_engine = "codex"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.default_engine == "codex"
    end

    @tag :tmp_dir
    test "parses bindings with queue_mode collect", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "collect"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.queue_mode == :collect
    end

    @tag :tmp_dir
    test "parses bindings with queue_mode followup", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "followup"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.queue_mode == :followup
    end

    @tag :tmp_dir
    test "parses bindings with queue_mode steer", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "steer"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.queue_mode == :steer
    end

    @tag :tmp_dir
    test "parses bindings with queue_mode interrupt", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "interrupt"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.queue_mode == :interrupt
    end

    @tag :tmp_dir
    test "parses multiple bindings", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 11111
      project = "app1"

      [[bindings]]
      transport = "telegram"
      chat_id = 22222
      project = "app2"

      [[bindings]]
      transport = "telegram"
      chat_id = 11111
      topic_id = 999
      project = "app1_topic"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert length(result[:bindings]) == 3

      chat_ids = Enum.map(result[:bindings], & &1.chat_id)
      assert 11111 in chat_ids
      assert 22222 in chat_ids
    end

    @tag :tmp_dir
    test "parses complete config with gateway, projects, and bindings", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"
      max_concurrent_runs = 10

      [projects.myapp]
      root = "#{project_root}"
      default_engine = "lemon"

      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      project = "myapp"
      queue_mode = "followup"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # Gateway settings
      assert result[:default_engine] == "claude"
      assert result[:max_concurrent_runs] == 10

      # Projects
      assert Map.has_key?(result[:projects], "myapp")
      assert result[:projects]["myapp"].default_engine == "lemon"

      # Bindings
      assert length(result[:bindings]) == 1
      binding = hd(result[:bindings])
      assert binding.project == "myapp"
      assert binding.queue_mode == :followup
    end
  end

  # ============================================================================
  # TOML Parsing - Invalid Files
  # ============================================================================

  describe "load/0 with invalid TOML file" do
    @tag :tmp_dir
    test "falls back to Application env on TOML syntax error", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Invalid TOML - missing closing bracket
      File.write!(config_path, """
      [gateway
      default_engine = "claude"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      # Should fall back to Application env
      assert result[:default_engine] == "fallback"
    end

    @tag :tmp_dir
    test "falls back to Application env on invalid TOML value", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Invalid TOML - malformed string
      File.write!(config_path, """
      [gateway]
      default_engine = "unterminated
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      assert result[:default_engine] == "fallback"
    end

    @tag :tmp_dir
    test "falls back to Application env on empty file", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, "")

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      # Empty TOML is valid, should return empty config
      assert result[:projects] == %{}
      assert result[:bindings] == []
    end
  end

  # ============================================================================
  # Missing File Handling
  # ============================================================================

  describe "load/0 with missing file" do
    test "falls back to Application env when file does not exist" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path/gateway.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback_engine")

      result = ConfigLoader.load()

      assert result[:default_engine] == "fallback_engine"
    end

    test "uses default path when config_path not set" do
      # Don't set config_path - should use default ~/.lemon/gateway.toml
      # which likely doesn't exist in test environment
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "env_default")

      result = ConfigLoader.load()

      # Falls back to Application env since default path doesn't exist
      assert result[:default_engine] == "env_default"
    end
  end

  # ============================================================================
  # Application Env Fallback
  # ============================================================================

  describe "load/0 from Application env" do
    test "loads config from Application env as keyword list" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config,
        default_engine: "claude",
        max_concurrent_runs: 3
      )

      result = ConfigLoader.load()

      assert result[:default_engine] == "claude"
      assert result[:max_concurrent_runs] == 3
    end

    test "loads config from Application env as map" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        default_engine: "codex",
        timeout_ms: 60000
      })

      result = ConfigLoader.load()

      assert result[:default_engine] == "codex"
      assert result[:timeout_ms] == 60000
    end

    test "parses projects from Application env with atom keys" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        projects: %{
          myapp: %{root: "/tmp/myapp", default_engine: "claude"}
        }
      })

      result = ConfigLoader.load()

      assert Map.has_key?(result[:projects], "myapp")
      project = result[:projects]["myapp"]
      assert %Project{} = project
      assert project.id == "myapp"
      assert project.root == "/tmp/myapp"
      assert project.default_engine == "claude"
    end

    test "parses projects from Application env with string keys" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        projects: %{
          "myapp" => %{"root" => "/tmp/myapp", "default_engine" => "lemon"}
        }
      })

      result = ConfigLoader.load()

      project = result[:projects]["myapp"]
      assert project.root == "/tmp/myapp"
      assert project.default_engine == "lemon"
    end

    test "parses bindings from Application env with atom keys" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp", queue_mode: :followup}
        ]
      })

      result = ConfigLoader.load()

      assert length(result[:bindings]) == 1
      binding = hd(result[:bindings])
      assert %Binding{} = binding
      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.queue_mode == :followup
    end

    test "parses bindings from Application env with string keys" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{"transport" => "telegram", "chat_id" => 12345, "queue_mode" => "collect"}
        ]
      })

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.transport == :telegram
      assert binding.queue_mode == :collect
    end

    test "returns empty projects and bindings when not configured" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{})

      result = ConfigLoader.load()

      assert result[:projects] == %{}
      assert result[:bindings] == []
    end

    test "returns empty config when Application env not set" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      # Don't set LemonGateway.Config

      result = ConfigLoader.load()

      assert result[:projects] == %{}
      assert result[:bindings] == []
    end
  end

  # ============================================================================
  # Default Values
  # ============================================================================

  describe "default values" do
    @tag :tmp_dir
    test "projects default_engine defaults to nil", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects.myapp]
      root = "#{project_root}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects]["myapp"].default_engine == nil
    end

    @tag :tmp_dir
    test "binding fields default to nil when not specified", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.topic_id == nil
      assert binding.project == nil
      assert binding.default_engine == nil
      assert binding.queue_mode == nil
    end

    @tag :tmp_dir
    test "gateway section defaults to empty when not specified", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # Only :projects and :bindings keys should be present from parsing
      assert result[:default_engine] == nil
      assert result[:max_concurrent_runs] == nil
    end
  end

  # ============================================================================
  # Transport Parsing
  # ============================================================================

  describe "transport parsing" do
    @tag :tmp_dir
    test "parses telegram transport string", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :telegram
    end

    @tag :tmp_dir
    test "parses custom transport string", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "discord"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :discord
    end

    test "parses atom transport from Application env" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 12345}
        ]
      })

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :telegram
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    @tag :tmp_dir
    test "handles whitespace-only TOML file", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, "   \n\t\n  ")

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects] == %{}
      assert result[:bindings] == []
    end

    @tag :tmp_dir
    test "handles comments-only TOML file", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      # This is a comment
      # Another comment
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects] == %{}
      assert result[:bindings] == []
    end

    @tag :tmp_dir
    test "handles TOML with inline comments", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"  # This is the default engine
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:default_engine] == "claude"
    end

    @tag :tmp_dir
    test "handles project with non-existent root directory", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "/nonexistent/project/path"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Should not raise, just log a warning
      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == "/nonexistent/project/path"
    end

    @tag :tmp_dir
    test "handles path expansion with tilde", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "~/myproject"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # The root is stored as-is, expansion happens when resolving cwd
      assert result[:projects]["myapp"].root == "~/myproject"
    end

    @tag :tmp_dir
    test "handles large chat_id values", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      large_chat_id = 9_999_999_999_999

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = #{large_chat_id}
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).chat_id == large_chat_id
    end

    @tag :tmp_dir
    test "handles negative chat_id values", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = -1001234567890
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).chat_id == -1_001_234_567_890
    end

    @tag :tmp_dir
    test "handles empty projects section", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"

      [projects]
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects] == %{}
    end

    @tag :tmp_dir
    test "handles empty bindings array", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:bindings] == []
    end

    @tag :tmp_dir
    test "handles project name with special characters", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects."my-app_v2.0"]
      root = "#{project_root}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert Map.has_key?(result[:projects], "my-app_v2.0")
    end

    @tag :tmp_dir
    test "handles unicode in project names and paths", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "proyecto")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects."proyecto"]
      root = "#{project_root}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert Map.has_key?(result[:projects], "proyecto")
    end
  end

  # ============================================================================
  # Queue Mode Parsing
  # ============================================================================

  describe "queue_mode parsing edge cases" do
    test "nil queue_mode returns nil" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: nil}
        ]
      })

      result = ConfigLoader.load()

      assert hd(result[:bindings]).queue_mode == nil
    end

    test "atom queue_mode passes through" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :followup}
        ]
      })

      result = ConfigLoader.load()

      assert hd(result[:bindings]).queue_mode == :followup
    end

    test "all valid queue_mode atoms pass through from Application env" do
      for mode <- [:collect, :followup, :steer, :interrupt] do
        Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
        Application.put_env(:lemon_gateway, LemonGateway.Config, %{
          bindings: [%{transport: :telegram, chat_id: 12345, queue_mode: mode}]
        })

        result = ConfigLoader.load()
        assert hd(result[:bindings]).queue_mode == mode
      end
    end

    test "custom atom queue_mode passes through unchanged" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :custom_mode}
        ]
      })

      result = ConfigLoader.load()

      # Non-standard atoms pass through as-is
      assert hd(result[:bindings]).queue_mode == :custom_mode
    end
  end

  # ============================================================================
  # Invalid Queue Mode Strings
  # ============================================================================

  describe "invalid queue_mode strings" do
    @tag :tmp_dir
    test "unrecognized queue_mode string raises FunctionClauseError", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "invalid_mode"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Unrecognized string modes raise FunctionClauseError
      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end

    @tag :tmp_dir
    test "empty string queue_mode raises FunctionClauseError", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = ""
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end

    @tag :tmp_dir
    test "case-sensitive queue_mode - uppercase raises error", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "COLLECT"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Uppercase doesn't match any clause
      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end

    @tag :tmp_dir
    test "mixed case queue_mode raises error", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      queue_mode = "Followup"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end
  end

  # ============================================================================
  # Key Conversion
  # ============================================================================

  describe "key conversion" do
    @tag :tmp_dir
    test "converts gateway string keys to atoms", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      default_engine = "claude"
      max_concurrent_runs = 5
      custom_setting = "value"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # All keys should be atoms
      assert result[:default_engine] == "claude"
      assert result[:max_concurrent_runs] == 5
      assert result[:custom_setting] == "value"
    end
  end

  # ============================================================================
  # TOML Malformed Files - Additional Tests
  # ============================================================================

  describe "malformed TOML files" do
    @tag :tmp_dir
    test "bindings as table instead of array of tables causes error", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Using [bindings] (table) instead of [[bindings]] (array of tables)
      # This is valid TOML but creates a map instead of a list
      File.write!(config_path, """
      [bindings]
      transport = "telegram"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      # When bindings is a map (from [bindings] table), Enum.map iterates over
      # key-value tuples, causing an error when trying to access fields
      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end

    @tag :tmp_dir
    test "duplicate keys in TOML section falls back", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Duplicate key - TOML parsers typically reject this
      File.write!(config_path, """
      [gateway]
      default_engine = "first"
      default_engine = "second"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      # TOML parser should reject duplicate keys and fallback
      assert result[:default_engine] == "fallback"
    end

    @tag :tmp_dir
    test "invalid nested table syntax falls back", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Invalid table path
      File.write!(config_path, """
      [projects..invalid]
      root = "/tmp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      assert result[:default_engine] == "fallback"
    end

    @tag :tmp_dir
    test "invalid value type - array where string expected", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Array instead of string - valid TOML but unexpected type
      File.write!(config_path, """
      [gateway]
      default_engine = ["claude", "codex"]
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # The value is stored as-is (array)
      assert result[:default_engine] == ["claude", "codex"]
    end

    # NOTE: Binary/non-UTF8 data in TOML file causes an unrecoverable crash
    # in Toml.Lexer.do_lex/3 which cannot be caught with try/catch because
    # the TOML library spawns a linked process that crashes. This is a known
    # limitation of the Toml library.
    #
    # Example test (commented out due to uncatchable crash):
    # @tag :tmp_dir
    # test "binary data in TOML file causes crash (lexer limitation)", %{tmp_dir: tmp_dir} do
    #   config_path = Path.join(tmp_dir, "gateway.toml")
    #   File.write!(config_path, <<0xFF, 0xFE, 0x00, 0x01>>)
    #   Application.put_env(:lemon_gateway, :config_path, config_path)
    #   # This will crash the test process
    #   ConfigLoader.load()
    # end

    @tag :tmp_dir
    test "truncated TOML file falls back", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # Truncated in middle of string
      File.write!(config_path, "[gateway]\ndefault_engine = \"clau")

      Application.put_env(:lemon_gateway, :config_path, config_path)
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      assert result[:default_engine] == "fallback"
    end
  end

  # ============================================================================
  # Path Expansion with ~
  # ============================================================================

  describe "path expansion" do
    test "config_path with ~ is expanded" do
      # Temporarily set to a path with ~
      Application.put_env(:lemon_gateway, :config_path, "~/nonexistent/gateway.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, default_engine: "fallback")

      result = ConfigLoader.load()

      # Since ~/nonexistent/gateway.toml doesn't exist, falls back to Application env
      assert result[:default_engine] == "fallback"
    end

    @tag :tmp_dir
    test "project root with ~ is stored as-is in struct", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "~/projects/myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # Root is stored as-is - expansion happens during cwd resolution
      assert result[:projects]["myapp"].root == "~/projects/myapp"
    end

    @tag :tmp_dir
    test "project root with relative path is stored as-is", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "./relative/path"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == "./relative/path"
    end

    @tag :tmp_dir
    test "project root with environment variable syntax is stored as-is", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "$HOME/projects/myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # $HOME is not expanded - stored as literal string
      assert result[:projects]["myapp"].root == "$HOME/projects/myapp"
    end
  end

  # ============================================================================
  # Non-existent Directory Fallback
  # ============================================================================

  describe "non-existent directory handling" do
    @tag :tmp_dir
    test "project with nil root passes validation", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # TOML doesn't have nil, so we just omit root
      File.write!(config_path, """
      [projects.myapp]
      default_engine = "claude"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == nil
    end

    @tag :tmp_dir
    test "multiple projects with mixed valid/invalid roots", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      valid_root = Path.join(tmp_dir, "valid_project")
      File.mkdir_p!(valid_root)

      File.write!(config_path, """
      [projects.valid]
      root = "#{valid_root}"

      [projects.invalid]
      root = "/nonexistent/path/123"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Should not raise - logs warning for invalid root
      result = ConfigLoader.load()

      assert result[:projects]["valid"].root == valid_root
      assert result[:projects]["invalid"].root == "/nonexistent/path/123"
    end

    test "project from Application env with non-existent root loads" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        projects: %{
          myapp: %{root: "/does/not/exist", default_engine: "claude"}
        }
      })

      # No validation happens for Application env - should load fine
      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == "/does/not/exist"
    end
  end

  # ============================================================================
  # Mixed Atom/String Keys in TOML Parsing
  # ============================================================================

  describe "mixed atom/string keys" do
    test "Application env with mixed keyword list and map config" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, [
        default_engine: "claude",
        projects: %{
          "app1" => %{"root" => "/tmp/app1"},
          :app2 => %{root: "/tmp/app2"}
        }
      ])

      result = ConfigLoader.load()

      assert result[:default_engine] == "claude"
      assert result[:projects]["app1"].root == "/tmp/app1"
      assert result[:projects]["app2"].root == "/tmp/app2"
    end

    test "bindings with mixed string/atom keys in same list" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :telegram, chat_id: 111},
          %{"transport" => "telegram", "chat_id" => 222}
        ]
      })

      result = ConfigLoader.load()

      assert length(result[:bindings]) == 2
      assert Enum.at(result[:bindings], 0).chat_id == 111
      assert Enum.at(result[:bindings], 1).chat_id == 222
    end

    test "project config with partially mixed keys" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        projects: %{
          myapp: %{"default_engine" => "mixed", root: "/tmp/app"}
        }
      })

      result = ConfigLoader.load()

      # Both atom and string keys should be handled
      assert result[:projects]["myapp"].root == "/tmp/app"
      assert result[:projects]["myapp"].default_engine == "mixed"
    end
  end

  # ============================================================================
  # Project Root Directory Validation
  # ============================================================================

  describe "project root validation" do
    @tag :tmp_dir
    test "validates existing directory succeeds silently", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "exists")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects.myapp]
      root = "#{project_root}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == project_root
    end

    @tag :tmp_dir
    test "validates file instead of directory logs warning", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      file_path = Path.join(tmp_dir, "afile.txt")
      File.write!(file_path, "content")

      File.write!(config_path, """
      [projects.myapp]
      root = "#{file_path}"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Should not raise, logs warning since it's a file not a directory
      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == file_path
    end

    @tag :tmp_dir
    test "validates path with ~ expansion", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = "~/definitely_nonexistent_path_12345"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Should expand ~ and check if directory exists (it won't)
      result = ConfigLoader.load()

      assert result[:projects]["myapp"].root == "~/definitely_nonexistent_path_12345"
    end

    @tag :tmp_dir
    test "validates symlink to directory", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      real_dir = Path.join(tmp_dir, "real_dir")
      symlink = Path.join(tmp_dir, "symlink_dir")
      File.mkdir_p!(real_dir)

      case File.ln_s(real_dir, symlink) do
        :ok ->
          File.write!(config_path, """
          [projects.myapp]
          root = "#{symlink}"
          """)

          Application.put_env(:lemon_gateway, :config_path, config_path)

          result = ConfigLoader.load()

          assert result[:projects]["myapp"].root == symlink

        {:error, :enotsup} ->
          # Symlinks not supported on this filesystem, skip
          :ok
      end
    end
  end

  # ============================================================================
  # Invalid Transport Names
  # ============================================================================

  describe "invalid transport names" do
    @tag :tmp_dir
    test "nil transport is stored as nil", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      # No transport specified
      File.write!(config_path, """
      [[bindings]]
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == nil
    end

    @tag :tmp_dir
    test "empty string transport becomes empty atom", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = ""
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # Empty string converts to :"" atom
      assert hd(result[:bindings]).transport == :""
    end

    @tag :tmp_dir
    test "numeric transport value raises FunctionClauseError", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = 123
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      # Integer doesn't match any parse_transport clause, raises error
      assert_raise FunctionClauseError, fn ->
        ConfigLoader.load()
      end
    end

    @tag :tmp_dir
    test "transport with special characters becomes atom", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "my-custom-transport"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :"my-custom-transport"
    end

    @tag :tmp_dir
    test "transport with spaces becomes atom", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "my transport"
      chat_id = 12345
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :"my transport"
    end

    test "transport atom from Application env passes through" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{transport: :custom_transport, chat_id: 12345}
        ]
      })

      result = ConfigLoader.load()

      assert hd(result[:bindings]).transport == :custom_transport
    end
  end

  # ============================================================================
  # Binding Resolution Edge Cases
  # ============================================================================

  describe "binding edge cases" do
    @tag :tmp_dir
    test "binding with only chat_id (no transport)", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      chat_id = 12345
      project = "myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.chat_id == 12345
      assert binding.transport == nil
      assert binding.project == "myapp"
    end

    @tag :tmp_dir
    test "binding with string chat_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = "12345"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # String chat_id is stored as string
      assert hd(result[:bindings]).chat_id == "12345"
    end

    @tag :tmp_dir
    test "binding with zero chat_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 0
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).chat_id == 0
    end

    @tag :tmp_dir
    test "binding with zero topic_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 0
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).topic_id == 0
    end

    @tag :tmp_dir
    test "binding with all fields populated", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 999
      project = "myproject"
      default_engine = "claude"
      queue_mode = "followup"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.topic_id == 999
      assert binding.project == "myproject"
      assert binding.default_engine == "claude"
      assert binding.queue_mode == :followup
    end

    @tag :tmp_dir
    test "multiple bindings for same chat with different topics", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      project = "default_project"

      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 100
      project = "topic_100_project"

      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 200
      project = "topic_200_project"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert length(result[:bindings]) == 3
      projects = Enum.map(result[:bindings], & &1.project)
      assert "default_project" in projects
      assert "topic_100_project" in projects
      assert "topic_200_project" in projects
    end

    @tag :tmp_dir
    test "binding without chat_id", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      project = "myapp"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.chat_id == nil
      assert binding.transport == :telegram
    end

    test "binding from Application env with nil values" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [
          %{
            transport: nil,
            chat_id: nil,
            topic_id: nil,
            project: nil,
            default_engine: nil,
            queue_mode: nil
          }
        ]
      })

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert binding.transport == nil
      assert binding.chat_id == nil
      assert binding.topic_id == nil
      assert binding.project == nil
      assert binding.default_engine == nil
      assert binding.queue_mode == nil
    end

    test "empty binding map from Application env" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        bindings: [%{}]
      })

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert %Binding{} = binding
      assert binding.transport == nil
      assert binding.chat_id == nil
    end
  end

  # ============================================================================
  # Additional TOML Edge Cases
  # ============================================================================

  describe "additional TOML parsing edge cases" do
    @tag :tmp_dir
    test "multiline strings in TOML", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      description = \"\"\"
      This is a
      multiline description
      \"\"\"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert String.contains?(result[:description], "multiline")
    end

    @tag :tmp_dir
    test "literal strings with backslashes", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [projects.myapp]
      root = 'C:\\Users\\test\\project'
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      # Literal strings preserve backslashes
      assert result[:projects]["myapp"].root == "C:\\Users\\test\\project"
    end

    @tag :tmp_dir
    test "integers in different formats", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 1_000_000
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert hd(result[:bindings]).chat_id == 1_000_000
    end

    @tag :tmp_dir
    test "boolean values in gateway config", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      enabled = true
      debug = false
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:enabled] == true
      assert result[:debug] == false
    end

    @tag :tmp_dir
    test "float values in gateway config", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      timeout_factor = 1.5
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:timeout_factor] == 1.5
    end

    @tag :tmp_dir
    test "nested inline tables", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      options = { retries = 3, delay = 100 }
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:options]["retries"] == 3
      assert result[:options]["delay"] == 100
    end

    @tag :tmp_dir
    test "array values in config", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [gateway]
      allowed_engines = ["claude", "codex", "lemon"]
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      assert result[:allowed_engines] == ["claude", "codex", "lemon"]
    end
  end

  # ============================================================================
  # Struct Field Verification
  # ============================================================================

  describe "struct field types" do
    @tag :tmp_dir
    test "Project struct has correct fields", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")
      project_root = Path.join(tmp_dir, "myproject")
      File.mkdir_p!(project_root)

      File.write!(config_path, """
      [projects.test]
      root = "#{project_root}"
      default_engine = "claude"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      project = result[:projects]["test"]
      assert %Project{} = project
      assert project.id == "test"
      assert is_binary(project.root)
      assert project.default_engine == "claude"
    end

    @tag :tmp_dir
    test "Binding struct has correct fields", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "gateway.toml")

      File.write!(config_path, """
      [[bindings]]
      transport = "telegram"
      chat_id = 12345
      topic_id = 999
      project = "myapp"
      default_engine = "codex"
      queue_mode = "steer"
      """)

      Application.put_env(:lemon_gateway, :config_path, config_path)

      result = ConfigLoader.load()

      binding = hd(result[:bindings])
      assert %Binding{} = binding
      assert is_atom(binding.transport)
      assert is_integer(binding.chat_id)
      assert is_integer(binding.topic_id)
      assert is_binary(binding.project)
      assert is_binary(binding.default_engine)
      assert is_atom(binding.queue_mode)
    end
  end
end
