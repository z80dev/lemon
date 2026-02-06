defmodule LemonCore.ConfigTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config

  setup do
    original_home = System.get_env("HOME")
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    %{home: tmp_dir}
  end

  test "merges global and project config with overrides", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent]
    default_provider = "anthropic"
    default_model = "claude-sonnet-4-20250514"

    [providers.anthropic]
    api_key = "global-key"
    """)

    project_dir = Path.join(home, "project")
    File.mkdir_p!(Path.join(project_dir, ".lemon"))

    File.write!(Path.join([project_dir, ".lemon", "config.toml"]), """
    [agent]
    default_model = "claude-opus-4-20250514"

    [providers.anthropic]
    api_key = "project-key"
    """)

    config = Config.load(project_dir)

    assert config.agent.default_provider == "anthropic"
    assert config.agent.default_model == "claude-opus-4-20250514"
    assert config.providers["anthropic"].api_key == "project-key"
  end

  test "env overrides provider keys and defaults", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent]
    default_model = "claude-sonnet-4-20250514"

    [providers.openai]
    api_key = "file-key"
    """)

    System.put_env("LEMON_DEFAULT_MODEL", "gpt-4o-mini")
    System.put_env("OPENAI_API_KEY", "env-key")

    config = Config.load()

    assert config.agent.default_model == "gpt-4o-mini"
    assert config.providers["openai"].api_key == "env-key"
  after
    System.delete_env("LEMON_DEFAULT_MODEL")
    System.delete_env("OPENAI_API_KEY")
  end

  test "env overrides TUI settings", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [tui]
    theme = "lemon"
    debug = false
    """)

    System.put_env("LEMON_THEME", "ocean")
    System.put_env("LEMON_DEBUG", "true")

    config = Config.load()

    assert config.tui.theme == "ocean"
    assert config.tui.debug == true
  after
    System.delete_env("LEMON_THEME")
    System.delete_env("LEMON_DEBUG")
  end

  test "env overrides CLI settings", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent.cli.codex]
    extra_args = ["-c", "notify=[]"]
    auto_approve = false

    [agent.cli.claude]
    dangerously_skip_permissions = true
    """)

    System.put_env("LEMON_CODEX_EXTRA_ARGS", "--foo bar")
    System.put_env("LEMON_CODEX_AUTO_APPROVE", "1")
    System.put_env("LEMON_CLAUDE_YOLO", "false")

    config = Config.load()

    assert config.agent.cli.codex.extra_args == ["--foo", "bar"]
    assert config.agent.cli.codex.auto_approve == true
    assert config.agent.cli.claude.dangerously_skip_permissions == false
  after
    System.delete_env("LEMON_CODEX_EXTRA_ARGS")
    System.delete_env("LEMON_CODEX_AUTO_APPROVE")
    System.delete_env("LEMON_CLAUDE_YOLO")
  end

  test "env overrides provider base_url", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [providers.anthropic]
    api_key = "file-key"
    """)

    System.put_env("ANTHROPIC_BASE_URL", "https://anthropic.example")

    config = Config.load()

    assert config.providers["anthropic"].base_url == "https://anthropic.example"
  after
    System.delete_env("ANTHROPIC_BASE_URL")
  end

  test "parses agents from config (including tool_policy)", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agents.default]
    name = "Daily Assistant"
    default_engine = "lemon"
    system_prompt = "You are my daily assistant."
    model = "anthropic:claude-sonnet-4-20250514"

    [agents.default.tool_policy]
    allow = "all"
    deny = ["process_kill"]
    require_approval = ["bash", "write"]
    no_reply = false
    """)

    config = Config.load()

    assert config.agents["default"].name == "Daily Assistant"
    assert config.agents["default"].default_engine == "lemon"
    assert config.agents["default"].system_prompt == "You are my daily assistant."
    assert config.agents["default"].model == "anthropic:claude-sonnet-4-20250514"
    assert config.agents["default"].tool_policy.allow == :all
    assert "process_kill" in config.agents["default"].tool_policy.deny
    assert "bash" in config.agents["default"].tool_policy.require_approval
  end

  test "parses gateway binding agent_id", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [gateway]
    enable_telegram = true

    [[gateway.bindings]]
    transport = "telegram"
    chat_id = 123
    agent_id = "daily"
    """)

    config = Config.load()

    [binding] = config.gateway.bindings
    assert binding.transport == "telegram"
    assert binding.chat_id == 123
    assert binding.agent_id == "daily"
  end
end
