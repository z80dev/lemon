defmodule LemonCore.ConfigTest do
  use ExUnit.Case, async: false

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

  test "env overrides opencode provider key and base_url", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [providers.opencode]
    api_key = "file-opencode-key"
    base_url = "https://config.opencode.local/v1"
    """)

    System.put_env("OPENCODE_API_KEY", "env-opencode-key")
    System.put_env("OPENCODE_BASE_URL", "https://opencode.ai/zen/v1")

    config = Config.load()

    assert config.providers["opencode"].api_key == "env-opencode-key"
    assert config.providers["opencode"].base_url == "https://opencode.ai/zen/v1"
  after
    System.delete_env("OPENCODE_API_KEY")
    System.delete_env("OPENCODE_BASE_URL")
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

  test "parses provider api_key_secret", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [providers.openai]
    api_key_secret = "llm_openai_api_key"
    """)

    config = Config.load()

    assert config.providers["openai"].api_key_secret == "llm_openai_api_key"
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

  test "parses tool policy profile for agents", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agents.default]
    name = "Daily Assistant"

    [agents.default.tool_policy]
    profile = "minimal_core"
    """)

    config = Config.load()

    assert config.agents["default"].tool_policy.profile == :minimal_core
  end

  test "supports defaults/runtime/profiles config aliases", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [defaults]
    provider = "openai"
    model = "openai:gpt-5"
    thinking_level = "high"
    engine = "codex"

    [runtime]
    theme = "default"

    [runtime.tools.web.search]
    provider = "perplexity"

    [profiles.default]
    name = "Default Profile"
    system_prompt = "You are concise."
    """)

    config = Config.load()

    assert config.agent.default_provider == "openai"
    assert config.agent.default_model == "openai:gpt-5"
    assert config.agent.default_thinking_level == :high
    assert config.agent.theme == "default"
    assert config.agent.tools.web.search.provider == "perplexity"

    assert config.agents["default"].name == "Default Profile"
    assert config.agents["default"].system_prompt == "You are concise."
    assert config.agents["default"].model == "openai:gpt-5"
    assert config.agents["default"].default_engine == "codex"
  end

  test "defaults model and engine are applied only to the default profile", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [defaults]
    model = "openai:gpt-5"
    engine = "codex"

    [profiles.worker]
    name = "Worker"
    """)

    config = Config.load()

    assert config.agents["default"].model == "openai:gpt-5"
    assert config.agents["default"].default_engine == "codex"
    assert config.agents["worker"].model == nil
    assert config.agents["worker"].default_engine == nil
  end

  test "runtime and profiles override legacy agent and agents sections", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent]
    default_model = "anthropic:legacy-model"
    theme = "legacy-theme"

    [runtime]
    theme = "runtime-theme"

    [agents.default]
    name = "Legacy Profile"
    model = "anthropic:legacy-profile-model"

    [profiles.default]
    name = "Runtime Profile"
    model = "openai:new-profile-model"
    """)

    config = Config.load()

    assert config.agent.default_model == "anthropic:legacy-model"
    assert config.agent.theme == "runtime-theme"
    assert config.agents["default"].name == "Runtime Profile"
    assert config.agents["default"].model == "openai:new-profile-model"
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

  test "parses gateway default_cwd", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [gateway]
    default_cwd = "  ~/workspace  "
    """)

    config = Config.load()

    assert config.gateway.default_cwd == "~/workspace"
  end

  test "parses logging settings", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [logging]
    file = "./logs/lemon.log"
    level = "debug"
    """)

    config = Config.load()

    assert config.logging.file == "./logs/lemon.log"
    assert config.logging.level == :debug
  end

  test "env overrides log file and log level", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [logging]
    file = "./logs/from-file.log"
    level = "info"
    """)

    System.put_env("LEMON_LOG_FILE", "./logs/from-env.log")
    System.put_env("LEMON_LOG_LEVEL", "warning")

    config = Config.load()

    assert config.logging.file == "./logs/from-env.log"
    assert config.logging.level == :warning
  after
    System.delete_env("LEMON_LOG_FILE")
    System.delete_env("LEMON_LOG_LEVEL")
  end

  test "parses web tool configuration under agent.tools", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent.tools.web.search]
    enabled = true
    provider = "perplexity"
    max_results = 7
    timeout_seconds = 42
    cache_ttl_minutes = 10

    [agent.tools.web.search.failover]
    enabled = false
    provider = "brave"

    [agent.tools.web.search.perplexity]
    api_key = "pplx-test"
    base_url = "https://api.perplexity.ai"
    model = "perplexity/sonar"

    [agent.tools.web.fetch]
    enabled = true
    max_chars = 64000
    timeout_seconds = 25
    cache_ttl_minutes = 5
    max_redirects = 2
    readability = false
    allow_private_network = false
    allowed_hostnames = ["example.com"]

    [agent.tools.web.fetch.firecrawl]
    enabled = true
    api_key = "fc-test"
    base_url = "https://api.firecrawl.dev"
    only_main_content = true
    max_age_ms = 123000
    timeout_seconds = 15

    [agent.tools.web.cache]
    persistent = true
    path = "~/.lemon/cache/custom-web-tools"
    max_entries = 250
    """)

    config = Config.load()
    tools = config.agent.tools

    assert tools.web.search.provider == "perplexity"
    assert tools.web.search.max_results == 7
    assert tools.web.search.timeout_seconds == 42
    assert tools.web.search.cache_ttl_minutes == 10
    assert tools.web.search.failover.enabled == false
    assert tools.web.search.failover.provider == "brave"
    assert tools.web.search.perplexity.model == "perplexity/sonar"

    assert tools.web.fetch.max_chars == 64_000
    assert tools.web.fetch.timeout_seconds == 25
    assert tools.web.fetch.cache_ttl_minutes == 5
    assert tools.web.fetch.max_redirects == 2
    assert tools.web.fetch.readability == false
    assert tools.web.fetch.allowed_hostnames == ["example.com"]

    assert tools.web.fetch.firecrawl.enabled == true
    assert tools.web.fetch.firecrawl.timeout_seconds == 15

    assert tools.web.cache.persistent == true
    assert tools.web.cache.path == "~/.lemon/cache/custom-web-tools"
    assert tools.web.cache.max_entries == 250
  end

  test "parses wasm tool configuration under agent.tools", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent.tools.wasm]
    enabled = true
    auto_build = false
    runtime_path = "/tmp/lemon-wasm-runtime"
    tool_paths = ["/tmp/project-tools", "/tmp/global-tools"]
    default_memory_limit = 20971520
    default_timeout_ms = 45000
    default_fuel_limit = 9000000
    cache_compiled = false
    cache_dir = "/tmp/wasm-cache"
    max_tool_invoke_depth = 6
    """)

    config = Config.load()
    wasm = config.agent.tools.wasm

    assert wasm.enabled == true
    assert wasm.auto_build == false
    assert wasm.runtime_path == "/tmp/lemon-wasm-runtime"
    assert wasm.tool_paths == ["/tmp/project-tools", "/tmp/global-tools"]
    assert wasm.default_memory_limit == 20_971_520
    assert wasm.default_timeout_ms == 45_000
    assert wasm.default_fuel_limit == 9_000_000
    assert wasm.cache_compiled == false
    assert wasm.cache_dir == "/tmp/wasm-cache"
    assert wasm.max_tool_invoke_depth == 6
  end

  test "env overrides wasm tool configuration", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent.tools.wasm]
    enabled = false
    auto_build = true
    runtime_path = "/tmp/from-file"
    tool_paths = ["/tmp/file-tools"]
    """)

    System.put_env("LEMON_WASM_ENABLED", "true")
    System.put_env("LEMON_WASM_RUNTIME_PATH", "/tmp/from-env")
    System.put_env("LEMON_WASM_TOOL_PATHS", "/tmp/env-a,/tmp/env-b")
    System.put_env("LEMON_WASM_AUTO_BUILD", "0")

    config = Config.load()
    wasm = config.agent.tools.wasm

    assert wasm.enabled == true
    assert wasm.runtime_path == "/tmp/from-env"
    assert wasm.tool_paths == ["/tmp/env-a", "/tmp/env-b"]
    assert wasm.auto_build == false
  after
    System.delete_env("LEMON_WASM_ENABLED")
    System.delete_env("LEMON_WASM_RUNTIME_PATH")
    System.delete_env("LEMON_WASM_TOOL_PATHS")
    System.delete_env("LEMON_WASM_AUTO_BUILD")
  end

  test "parses gateway telegram compaction settings", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [gateway]
    enable_telegram = true

    [gateway.telegram.compaction]
    enabled = true
    context_window_tokens = 400000
    reserve_tokens = 16384
    trigger_ratio = 0.9
    """)

    config = Config.load()

    assert config.gateway.telegram.compaction.enabled == true
    assert config.gateway.telegram.compaction.context_window_tokens == 400_000
    assert config.gateway.telegram.compaction.reserve_tokens == 16_384
    assert config.gateway.telegram.compaction.trigger_ratio == 0.9
  end
end
