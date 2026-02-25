defmodule LemonGateway.BindingResolverTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Binding, ChatScope, ResumeToken}
  alias LemonGateway.{BindingResolver, Config}

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    # Clean up any existing config
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    # LemonCore.Store is shared across apps; ensure per-test isolation for any dynamic
    # project state that may have been persisted by other tests (or prior runs).
    try do
      _ = Application.ensure_all_started(:lemon_core)

      for {key, _} <- LemonCore.Store.list(:gateway_projects_dynamic) do
        :ok = LemonCore.Store.delete(:gateway_projects_dynamic, key)
      end

      for {key, _} <- LemonCore.Store.list(:gateway_project_overrides) do
        :ok = LemonCore.Store.delete(:gateway_project_overrides, key)
      end
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
    end)

    :ok
  end

  # Helper to set up config and start the application
  defp setup_config(config) do
    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
    Application.put_env(:lemon_gateway, Config, config)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  end

  describe "resolve_binding/1" do
    test "returns nil when no bindings configured" do
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "returns nil when bindings is nil" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "finds chat-level binding" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp", default_engine: "codex"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)

      assert %Binding{transport: :telegram, chat_id: 12345} = binding
      assert binding.project == "myapp"
      assert binding.default_engine == "codex"
    end

    test "topic binding takes precedence over chat binding" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "chat_project"},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "topic_project"}
        ]
      )

      # Chat-level scope gets chat binding
      chat_scope = %ChatScope{transport: :telegram, chat_id: 12345}
      chat_binding = BindingResolver.resolve_binding(chat_scope)
      assert chat_binding.project == "chat_project"

      # Topic scope gets topic binding
      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}
      topic_binding = BindingResolver.resolve_binding(topic_scope)
      assert topic_binding.project == "topic_project"
    end

    test "topic binding with all fields set correctly" do
      setup_config(
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            topic_id: 777,
            project: "topic_proj",
            default_engine: "topic_engine",
            queue_mode: :steer
          }
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 777}
      binding = BindingResolver.resolve_binding(scope)

      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.topic_id == 777
      assert binding.project == "topic_proj"
      assert binding.default_engine == "topic_engine"
      assert binding.queue_mode == :steer
    end

    test "falls back to chat binding when no topic binding exists" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "chat_project"}
        ]
      )

      # Topic scope falls back to chat binding
      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 888}
      binding = BindingResolver.resolve_binding(topic_scope)
      assert binding.project == "chat_project"
    end

    test "does not match topic binding when scope has no topic_id" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "topic_only"}
        ]
      )

      # Chat scope should NOT match topic binding
      chat_scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(chat_scope)
      assert binding == nil
    end

    test "handles binding with nil topic_id as chat-level binding" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, topic_id: nil, project: "chat_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      assert binding.project == "chat_proj"
    end

    test "handles binding with all fields populated" do
      setup_config(
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            project: "full_proj",
            default_engine: "full_engine",
            queue_mode: :collect
          }
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)

      assert %Binding{} = binding
      assert binding.project == "full_proj"
      assert binding.default_engine == "full_engine"
      assert binding.queue_mode == :collect
    end

    test "handles multiple bindings with different chat_ids" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 11111, project: "first_proj"},
          %{transport: :telegram, chat_id: 22222, project: "second_proj"}
        ]
      )

      scope1 = %ChatScope{transport: :telegram, chat_id: 11111}
      binding1 = BindingResolver.resolve_binding(scope1)
      assert binding1.project == "first_proj"

      scope2 = %ChatScope{transport: :telegram, chat_id: 22222}
      binding2 = BindingResolver.resolve_binding(scope2)
      assert binding2.project == "second_proj"
    end

    test "handles map with string keys via ConfigLoader" do
      # ConfigLoader handles string keys by checking both atom and string keys
      setup_config(
        bindings: [
          %{"transport" => "telegram", "chat_id" => 12345, "project" => "string_key_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)

      # ConfigLoader converts string keys to proper Binding struct
      assert %Binding{} = binding
      assert binding.project == "string_key_proj"
    end

    test "returns nil for non-matching transport" do
      setup_config(
        bindings: [
          %{transport: :discord, chat_id: 12345, project: "discord_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      assert binding == nil
    end

    test "returns nil for non-matching chat_id" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 99999, project: "other_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      assert binding == nil
    end

    test "handles empty binding map" do
      setup_config(bindings: [%{}])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      assert binding == nil
    end

    test "handles binding with only transport set" do
      setup_config(
        bindings: [
          %{transport: :telegram}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      # chat_id won't match nil
      assert binding == nil
    end

    test "multiple chat bindings returns first matching" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "first_proj"},
          %{transport: :telegram, chat_id: 12345, project: "second_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)
      assert binding.project == "first_proj"
    end

    test "multiple topic bindings returns first matching" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "first_topic"},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "second_topic"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}
      binding = BindingResolver.resolve_binding(scope)
      assert binding.project == "first_topic"
    end
  end

  describe "resolve_engine/3" do
    test "resume token engine takes highest precedence" do
      setup_config(
        default_engine: "global_default",
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "binding_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      resume = %ResumeToken{engine: "resume_engine", value: "abc123"}

      # Resume token wins over everything
      assert BindingResolver.resolve_engine(scope, "hint_engine", resume) == "resume_engine"
    end

    test "resume token with nil engine falls back to hint" do
      setup_config(
        default_engine: "global_default",
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "binding_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      # Create a map that mimics a resume token with nil engine
      resume = %{engine: nil, value: "abc123"}

      # Falls back to hint since resume.engine is nil
      assert BindingResolver.resolve_engine(scope, "hint_engine", resume) == "hint_engine"
    end

    test "engine hint takes precedence over binding" do
      setup_config(
        default_engine: "global_default",
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "binding_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Hint wins over binding
      assert BindingResolver.resolve_engine(scope, "hint_engine", nil) == "hint_engine"
    end

    test "topic binding engine takes precedence over chat binding" do
      setup_config(
        default_engine: "global_default",
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "chat_engine"},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, default_engine: "topic_engine"}
        ]
      )

      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}

      # Topic binding engine wins
      assert BindingResolver.resolve_engine(topic_scope, nil, nil) == "topic_engine"
    end

    test "chat binding engine takes precedence over project default" do
      File.mkdir_p!("/tmp/test_project")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "test_proj" => %{root: "/tmp/test_project", default_engine: "project_engine"}
        },
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            project: "test_proj",
            default_engine: "chat_engine"
          }
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Chat binding engine wins over project
      assert BindingResolver.resolve_engine(scope, nil, nil) == "chat_engine"
    end

    test "project default engine takes precedence over global" do
      File.mkdir_p!("/tmp/test_project2")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "test_proj" => %{root: "/tmp/test_project2", default_engine: "project_engine"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "test_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Project engine wins over global
      assert BindingResolver.resolve_engine(scope, nil, nil) == "project_engine"
    end

    test "falls back to global default when no other engine specified" do
      setup_config(default_engine: "global_default")

      scope = %ChatScope{transport: :telegram, chat_id: 99999}

      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_default"
    end

    test "returns Config default_engine when no engine configured in binding/project" do
      # Config module has a default_engine of "lemon" when not explicitly set
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 99999}

      # Falls back to Config's default value
      assert BindingResolver.resolve_engine(scope, nil, nil) == "lemon"
    end

    test "uses ConfigLoader default_engine when Config process is not running" do
      assert Process.whereis(Config) == nil
      Application.put_env(:lemon_gateway, Config, default_engine: "loader_default")

      scope = %ChatScope{transport: :telegram, chat_id: 99999}

      assert BindingResolver.resolve_engine(scope, nil, nil) == "loader_default"
    end

    test "falls back to lemon when Config process is not running and loader has no default" do
      assert Process.whereis(Config) == nil

      scope = %ChatScope{transport: :telegram, chat_id: 99999}

      assert BindingResolver.resolve_engine(scope, nil, nil) == "lemon"
    end

    test "binding with project but no project engine falls back to global" do
      File.mkdir_p!("/tmp/test_project_no_engine")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "test_proj" => %{root: "/tmp/test_project_no_engine"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "test_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Falls back to global since project has no default_engine
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_default"
    end

    test "binding with non-existent project falls back to global" do
      setup_config(
        default_engine: "global_default",
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "nonexistent_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Falls back to global since project doesn't exist
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_default"
    end

    test "binding with nil default_engine and project uses project engine" do
      File.mkdir_p!("/tmp/test_project_for_nil")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "proj" => %{root: "/tmp/test_project_for_nil", default_engine: "proj_engine"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "proj", default_engine: nil}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # binding.default_engine is nil, so falls through to project engine
      assert BindingResolver.resolve_engine(scope, nil, nil) == "proj_engine"
    end

    test "empty hint string is truthy and used" do
      setup_config(
        default_engine: "global_default",
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "binding_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Empty string is truthy in Elixir, so it's used as the hint
      assert BindingResolver.resolve_engine(scope, "", nil) == ""
    end

    test "projects config being empty is handled" do
      setup_config(
        default_engine: "global_default",
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "some_proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Falls back to global since project doesn't exist
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_default"
    end

    test "project with non-string default_engine is ignored" do
      File.mkdir_p!("/tmp/test_project_int_engine")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "proj" => %{root: "/tmp/test_project_int_engine", default_engine: 123}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Falls back to global since project engine is not a string
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_default"
    end

    test "full priority chain: resume > hint > topic > chat > project > global" do
      File.mkdir_p!("/tmp/test_full_chain")

      setup_config(
        default_engine: "global_default",
        projects: %{
          "chain_proj" => %{root: "/tmp/test_full_chain", default_engine: "project_engine"}
        },
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            project: "chain_proj",
            default_engine: "chat_engine"
          },
          %{transport: :telegram, chat_id: 12345, topic_id: 999, default_engine: "topic_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}
      resume = %ResumeToken{engine: "resume_engine", value: "abc"}

      # Test each level of priority by removing higher priority items
      # 1. Resume wins
      assert BindingResolver.resolve_engine(scope, "hint", resume) == "resume_engine"

      # 2. Hint wins (no resume)
      assert BindingResolver.resolve_engine(scope, "hint", nil) == "hint"

      # 3. Topic binding wins (no hint)
      assert BindingResolver.resolve_engine(scope, nil, nil) == "topic_engine"

      # 4. Chat binding wins (chat scope, no hint)
      chat_scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_engine(chat_scope, nil, nil) == "chat_engine"
    end
  end

  describe "resolve_cwd/1" do
    test "returns nil when no binding exists" do
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when binding has no project" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "codex"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when binding project is nil" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: nil}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns expanded project root path" do
      File.mkdir_p!("/tmp/my_project")

      setup_config(
        projects: %{
          "myapp" => %{root: "/tmp/my_project"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == "/tmp/my_project"
    end

    test "returns nil when project not found in projects config" do
      setup_config(
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "missing_project"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when project has no root field" do
      setup_config(
        projects: %{
          "myapp" => %{default_engine: "codex"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when project root is not a string" do
      setup_config(
        projects: %{
          "myapp" => %{root: 12345}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when project root is nil" do
      setup_config(
        projects: %{
          "myapp" => %{root: nil}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "returns nil when projects config is empty map" do
      setup_config(
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "expands relative path with tilde" do
      setup_config(
        projects: %{
          "myapp" => %{root: "~/some_project"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      result = BindingResolver.resolve_cwd(scope)

      # Path.expand will expand ~ to home directory
      assert result == Path.expand("~/some_project")
      refute result == "~/some_project"
    end

    test "topic binding project takes precedence for cwd" do
      File.mkdir_p!("/tmp/topic_project")
      File.mkdir_p!("/tmp/chat_project")

      setup_config(
        projects: %{
          "topic_proj" => %{root: "/tmp/topic_project"},
          "chat_proj" => %{root: "/tmp/chat_project"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "chat_proj"},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "topic_proj"}
        ]
      )

      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}

      assert BindingResolver.resolve_cwd(topic_scope) == "/tmp/topic_project"
    end
  end

  describe "resolve_queue_mode/1" do
    test "returns nil when no binding exists" do
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "returns nil when binding has no queue_mode" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "myapp"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "returns nil when binding queue_mode is nil" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: nil}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "returns queue mode from binding" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :followup}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :followup
    end

    test "normalizes string queue_mode 'steer' to atom" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: "steer"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :steer
    end

    test "normalizes string queue_mode 'collect' to atom" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: "collect"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :collect
    end

    test "normalizes string queue_mode 'followup' to atom" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: "followup"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :followup
    end

    test "normalizes string queue_mode 'interrupt' to atom" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: "interrupt"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :interrupt
    end

    test "preserves atom queue_mode unchanged" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :collect}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :collect
    end

    test "topic binding queue_mode takes precedence" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :collect},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, queue_mode: :interrupt}
        ]
      )

      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}

      assert BindingResolver.resolve_queue_mode(topic_scope) == :interrupt
    end

    test "falls back to chat binding queue_mode when topic has none" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :steer},
          %{transport: :telegram, chat_id: 12345, topic_id: 999, project: "topic_proj"}
        ]
      )

      # Topic binding exists but has no queue_mode, so use topic binding's nil queue_mode
      # (topic binding takes precedence, even if its queue_mode is nil)
      topic_scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}

      # The topic binding is selected, but it has no queue_mode, so nil is returned
      assert BindingResolver.resolve_queue_mode(topic_scope) == nil
    end

    test "handles map binding with queue_mode" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :followup}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :followup
    end

    test "map binding queue_mode string is normalized" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: "steer"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      assert BindingResolver.resolve_queue_mode(scope) == :steer
    end
  end

  describe "normalize_binding/1 edge cases" do
    test "normalizes map binding to Binding struct" do
      setup_config(
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            topic_id: 999,
            project: "myproj",
            default_engine: "myengine",
            queue_mode: "collect"
          }
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 999}
      binding = BindingResolver.resolve_binding(scope)

      assert %Binding{} = binding
      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.topic_id == 999
      assert binding.project == "myproj"
      assert binding.default_engine == "myengine"
      assert binding.queue_mode == :collect
    end

    test "normalizes map binding queue_mode string" do
      setup_config(
        bindings: [
          %{
            transport: :telegram,
            chat_id: 12345,
            queue_mode: "interrupt"
          }
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)

      assert binding.queue_mode == :interrupt
    end

    test "handles binding with missing optional fields" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      binding = BindingResolver.resolve_binding(scope)

      assert %Binding{} = binding
      assert binding.transport == :telegram
      assert binding.chat_id == 12345
      assert binding.topic_id == nil
      assert binding.project == nil
      assert binding.default_engine == nil
      assert binding.queue_mode == nil
    end
  end

  describe "Config.get integration" do
    test "uses Config.get(:bindings) for resolve_binding" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 11111, project: "proj1"}
        ]
      )

      # Verify Config.get returns expected bindings
      bindings = Config.get(:bindings)
      assert is_list(bindings)
      assert length(bindings) == 1

      scope = %ChatScope{transport: :telegram, chat_id: 11111}
      binding = BindingResolver.resolve_binding(scope)
      assert binding.project == "proj1"
    end

    test "uses Config.get(:projects) for resolve_cwd" do
      File.mkdir_p!("/tmp/config_test_proj")

      setup_config(
        projects: %{
          "config_proj" => %{root: "/tmp/config_test_proj"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "config_proj"}
        ]
      )

      # Verify Config.get returns expected projects
      projects = Config.get(:projects)
      assert is_map(projects)
      assert Map.has_key?(projects, "config_proj")

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == "/tmp/config_test_proj"
    end

    test "uses Config.get(:default_engine) as fallback" do
      setup_config(default_engine: "config_default_engine")

      # Verify Config.get returns expected default_engine
      assert Config.get(:default_engine) == "config_default_engine"

      scope = %ChatScope{transport: :telegram, chat_id: 99999}
      assert BindingResolver.resolve_engine(scope, nil, nil) == "config_default_engine"
    end

    test "handles Config.get returning nil for bindings" do
      # Start with minimal config that doesn't set bindings
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      Application.put_env(:lemon_gateway, Config, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      # Should handle nil bindings gracefully
      assert BindingResolver.resolve_binding(scope) == nil
    end
  end

  describe "fallback chains" do
    test "engine fallback: no binding -> global default" do
      setup_config(default_engine: "global_engine")

      scope = %ChatScope{transport: :telegram, chat_id: 99999}
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_engine"
    end

    test "engine fallback: binding without engine or project -> global default" do
      setup_config(
        default_engine: "global_engine",
        bindings: [
          %{transport: :telegram, chat_id: 12345}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_engine"
    end

    test "engine fallback: binding with project but project missing -> global default" do
      setup_config(
        default_engine: "global_engine",
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "nonexistent"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_engine"
    end

    test "engine fallback: binding with project but project has no engine -> global default" do
      File.mkdir_p!("/tmp/no_engine_proj")

      setup_config(
        default_engine: "global_engine",
        projects: %{
          "no_engine" => %{root: "/tmp/no_engine_proj"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "no_engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_engine(scope, nil, nil) == "global_engine"
    end

    test "cwd fallback: no binding -> nil" do
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "cwd fallback: binding without project -> nil" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, default_engine: "engine"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "cwd fallback: binding with project but project missing -> nil" do
      setup_config(
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "missing"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "cwd fallback: binding with project but project has no root -> nil" do
      setup_config(
        projects: %{
          "no_root" => %{default_engine: "engine"}
        },
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "no_root"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "queue_mode fallback: no binding -> nil" do
      setup_config([])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "queue_mode fallback: binding without queue_mode -> nil" do
      setup_config(
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "proj"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_queue_mode(scope) == nil
    end
  end

  describe "empty/nil binding handling" do
    test "empty bindings list returns nil" do
      setup_config(bindings: [])

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "binding with all nil values doesn't match" do
      setup_config(
        bindings: [
          %{transport: nil, chat_id: nil, project: nil}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "empty map binding doesn't match specific scope" do
      setup_config(
        bindings: [
          %{}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      # transport and chat_id are nil in the binding, won't match
      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "map binding with only transport doesn't match" do
      setup_config(
        bindings: [
          %{transport: :telegram}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      # chat_id is nil in binding, won't match
      assert BindingResolver.resolve_binding(scope) == nil
    end

    test "empty projects map returns nil for cwd" do
      setup_config(
        projects: %{},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "any"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "empty project entry returns nil for cwd" do
      setup_config(
        projects: %{"empty" => %{}},
        bindings: [
          %{transport: :telegram, chat_id: 12345, project: "empty"}
        ]
      )

      scope = %ChatScope{transport: :telegram, chat_id: 12345}
      assert BindingResolver.resolve_cwd(scope) == nil
    end
  end
end
