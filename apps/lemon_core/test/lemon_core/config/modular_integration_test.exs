defmodule LemonCore.Config.ModularIntegrationTest do
  @moduledoc """
  Integration tests for modular config with validation.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Config.Modular
  alias LemonCore.Config.ValidationError

  setup do
    # Create a temporary directory for test configs
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "modular_integration_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  test "real TOML budget caps merge globally and project overrides retain zero", %{
    mock_home: home,
    tmp_dir: project
  } do
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))

    File.write!(Path.join(home, ".lemon/config.toml"), """
    [budgets]
    max_run_tokens = 500
    max_run_cost_usd = 1.5
    max_session_tokens = 2000
    """)

    File.write!(Path.join(project, ".lemon/config.toml"), """
    [budgets]
    max_run_tokens = 0
    max_session_cost_usd = 4
    """)

    config = LemonCore.Config.load_base_from_disk(project)

    assert config.budgets == %{
             max_run_tokens: 0,
             max_run_cost_usd: 1.5,
             max_session_tokens: 2000,
             max_session_cost_usd: 4
           }

    assert LemonCore.Config.to_map(config).budgets == config.budgets
  end

  test "model-only project overrides retain provider inheritance through both load APIs", %{
    mock_home: home,
    tmp_dir: project
  } do
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))

    File.write!(Path.join(home, ".lemon/config.toml"), """
    [defaults]
    provider = "ollama"
    model = "qwen:7b"
    """)

    path = Path.join(project, ".lemon/config.toml")
    File.write!(path, "[defaults]\nmodel = \"anthropic:claude-sonnet-5\"\n")

    assert Modular.load(project_dir: project).agent.default_provider_source == :inherited
    assert {:ok, config} = Modular.load_with_validation(project_dir: project)
    assert config.agent.default_provider == "ollama"
    assert config.agent.default_model == "anthropic:claude-sonnet-5"
    assert config.agent.default_provider_source == :inherited

    File.write!(path, """
    [defaults]
    provider = "ollama"
    model = "anthropic:claude-sonnet-5"
    """)

    assert Modular.load(project_dir: project).agent.default_provider_source == :explicit
    assert {:ok, config} = Modular.load_with_validation(project_dir: project)
    assert config.agent.default_provider_source == :explicit
  end

  test "omitted caps are unlimited and invalid caps fail validation and runtime loading", %{
    tmp_dir: project
  } do
    assert {:ok, config} = Modular.validate_settings(%{})
    assert Enum.all?(config.budgets, fn {_key, value} -> is_nil(value) end)

    for {key, invalid} <- [
          {"max_run_tokens", -1},
          {"max_session_tokens", 0.5},
          {"max_run_cost_usd", -0.01},
          {"max_session_cost_usd", "unlimited"}
        ] do
      assert {:error, errors} = Modular.validate_settings(%{"budgets" => %{key => invalid}})
      assert Enum.any?(errors, &String.contains?(&1, "budgets.#{key}"))
    end

    File.mkdir_p!(Path.join(project, ".lemon"))
    File.write!(Path.join(project, ".lemon/config.toml"), "[budgets]\nmax_run_tokens = -1\n")
    assert_raise ValidationError, fn -> Modular.load(project_dir: project) end
  end

  describe "load/1 with validation" do
    test "loads valid config with validation by default", %{mock_home: mock_home} do
      # Create a minimal valid config using canonical sections
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "test-model"
      """)

      config = Modular.load()

      assert is_struct(config, Modular)
      assert config.agent.default_model == "test-model"
    end

    test "validates config when validate: true", %{mock_home: mock_home} do
      # An empty model must not reach runtime consumers.
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = ""
      """)

      error = assert_raise ValidationError, fn -> Modular.load(validate: true) end
      assert Exception.message(error) =~ Path.join(global_config, "config.toml")
      assert Exception.message(error) =~ "agent.default_model"
      assert_raise ValidationError, fn -> Modular.load() end
      assert Modular.load(validate: false).agent.default_model == ""
    end

    test "returns valid config when validation passes", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "claude-sonnet-4"

      [logging]
      level = "info"
      """)

      config = Modular.load(validate: true)

      assert is_struct(config, Modular)
      assert config.agent.default_model == "claude-sonnet-4"
    end

    test "loads defaults/runtime aliases", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      provider = "openai"
      model = "openai:gpt-5"
      thinking_level = "high"

      """)

      config = Modular.load(validate: true)

      assert is_struct(config, Modular)
      assert config.agent.default_provider == "openai"
      assert config.agent.default_model == "openai:gpt-5"
      assert config.agent.default_thinking_level == "high"
    end
  end

  describe "load!/1" do
    test "returns config when valid", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "valid-model"
      """)

      config = Modular.load!()

      assert is_struct(config, Modular)
      assert config.agent.default_model == "valid-model"
    end

    test "raises ValidationError when config is invalid", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = ""
      """)

      assert_raise ValidationError, fn ->
        Modular.load!()
      end
    end

    test "includes error details in exception", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = ""
      provider = ""
      """)

      try do
        Modular.load!()
        flunk("Expected ValidationError to be raised")
      rescue
        e in ValidationError ->
          assert e.message =~ "Configuration validation failed"
          assert e.errors != []
          assert Enum.any?(e.errors, &String.contains?(&1, "agent.default_model"))
      end
    end
  end

  describe "load_with_validation/1" do
    test "returns {:ok, config} for valid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "valid-model"
      """)

      assert {:ok, config} = Modular.load_with_validation()
      assert is_struct(config, Modular)
    end

    test "returns {:error, errors} for invalid config", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = ""
      """)

      assert {:error, _errors} = Modular.load_with_validation()
    end

    test "includes specific error messages", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = ""
      provider = ""

      [gateway]
      max_concurrent_runs = -1
      """)

      assert {:error, errors} = Modular.load_with_validation()

      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_provider"))
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))
    end
  end

  describe "project directory option" do
    test "loads config from specified project directory", %{
      tmp_dir: tmp_dir,
      mock_home: mock_home
    } do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "global-model"
      """)

      # Create project config
      project_dir = Path.join(tmp_dir, "my-project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [defaults]
      model = "project-model"
      """)

      config = Modular.load(project_dir: project_dir)

      assert config.agent.default_model == "project-model"
    end

    test "validates config from project directory", %{tmp_dir: tmp_dir, mock_home: mock_home} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [defaults]
      model = "global-model"
      """)

      # Create project config with invalid values
      project_dir = Path.join(tmp_dir, "my-project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [defaults]
      model = ""
      """)

      assert {:error, errors} = Modular.load_with_validation(project_dir: project_dir)
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
    end
  end

  describe "empty config handling" do
    test "handles missing config files gracefully", %{mock_home: _mock_home} do
      # No config files created
      config = Modular.load_with_validation()

      # Should return ok with defaults
      assert {:ok, _config} = config
    end

    test "handles empty config with validation", %{mock_home: mock_home} do
      # Create empty config files
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)
      File.write!(Path.join(global_config, "config.toml"), "")

      # Should return ok (all fields are optional)
      assert {:ok, _config} = Modular.load_with_validation()
    end
  end

  describe "deprecated sections" do
    test "loads a legacy [agent] section as its canonical sections, with a warning",
         %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_provider = "openai"
      default_model = "openai:test-model"
      theme = "light"
      max_tool_turns = 40
      """)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          config = Modular.load()

          assert config.agent.default_provider == "openai"
          assert config.agent.default_model == "openai:test-model"
          assert config.agent.max_tool_turns == 40
          assert config.tui.theme == "light"
        end)

      assert log =~ "[agent] is deprecated"
      assert log =~ "lemon config migrate"
      assert [warning] = Modular.deprecation_warnings()
      assert warning =~ "[agent] is deprecated"
    end

    test "raises on [agents] section", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agents.default]
      name = "Default"
      """)

      assert_raise ValidationError, ~r/deprecated/i, fn ->
        Modular.load()
      end
    end
  end
end
