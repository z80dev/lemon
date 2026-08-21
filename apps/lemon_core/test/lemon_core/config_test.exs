defmodule LemonCore.ConfigTest.StubChannel do
  @behaviour LemonCore.Config.Gateway.Channel

  @impl true
  def id, do: :stub

  @impl true
  def resolve(section), do: %{resolved: true, raw: section}

  @impl true
  def enabled?(configured), do: configured

  @impl true
  def validate(section, errors) do
    if Map.get(section, :resolved), do: errors, else: ["gateway.stub: invalid" | errors]
  end
end

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

  # The legacy map flattens whatever `:gateway_channels` holds. Run against a
  # stub so the flattening is proven without naming a platform (real channel
  # modules may be registered by other suites in this VM), and clear the shared
  # ConfigCache so the stub-shaped resolution is not served to later tests.
  setup do
    previous = Application.get_env(:lemon_core, :gateway_channels)
    Application.put_env(:lemon_core, :gateway_channels, [__MODULE__.StubChannel])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_core, :gateway_channels),
        else: Application.put_env(:lemon_core, :gateway_channels, previous)

      LemonCore.ConfigCache.clear()
    end)

    :ok
  end

  test "merges global and project config with overrides", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [defaults]
    provider = "anthropic"
    model = "claude-sonnet-4-20250514"

    [providers.anthropic]
    api_key = "global-key"
    """)

    project_dir = Path.join(home, "project")
    File.mkdir_p!(Path.join(project_dir, ".lemon"))

    File.write!(Path.join([project_dir, ".lemon", "config.toml"]), """
    [defaults]
    model = "claude-opus-4-20250514"

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
    [defaults]
    model = "claude-sonnet-4-20250514"

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

    System.put_env("LEMON_TUI_THEME", "ocean")
    System.put_env("LEMON_TUI_DEBUG", "true")

    config = Config.load()

    assert config.tui.theme == "ocean"
    assert config.tui.debug == true
  after
    System.delete_env("LEMON_TUI_THEME")
    System.delete_env("LEMON_TUI_DEBUG")
  end

  # Vendor CLI sections are resolved by registered `LemonCore.Config.CliResolvers`
  # (vendor packages register theirs at boot). With none registered, the raw
  # sections pass through untouched — nothing is dropped, and nothing in core
  # knows a vendor. The vendor-shaped round-trip lives in lemon_cli_runners'
  # CliResolversTest. Other suites in this VM may have booted vendor packages,
  # so run against an emptied registry and restore it after.
  test "carries unresolved CLI sections from the runtime section", %{home: home} do
    original = Application.fetch_env(:lemon_core, :cli_resolvers)
    Application.put_env(:lemon_core, :cli_resolvers, [])

    on_exit(fn ->
      case original do
        {:ok, resolvers} -> Application.put_env(:lemon_core, :cli_resolvers, resolvers)
        :error -> Application.delete_env(:lemon_core, :cli_resolvers)
      end

      LemonCore.ConfigCache.clear()
    end)

    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.cli.codex]
    extra_args = ["-c", "notify=[]"]
    auto_approve = false

    [runtime.cli.claude]
    dangerously_skip_permissions = true
    """)

    config = Config.load()

    assert config.agent.cli["codex"] == %{
             "extra_args" => ["-c", "notify=[]"],
             "auto_approve" => false
           }

    assert config.agent.cli["claude"] == %{"dangerously_skip_permissions" => true}
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

  test "parses agents from profiles config (including tool_policy)", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [profiles.default]
    name = "Daily Assistant"
    system_prompt = "You are my daily assistant."
    model = "anthropic:claude-sonnet-4-20250514"

    [profiles.default.tool_policy]
    allow = "all"
    deny = ["process_kill"]
    require_approval = ["bash", "write"]
    no_reply = false
    """)

    config = Config.load()

    assert config.agents["default"].name == "Daily Assistant"
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
    [profiles.default]
    name = "Daily Assistant"

    [profiles.default.tool_policy]
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
  end

  test "defaults model is applied only to the default profile", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [defaults]
    model = "openai:gpt-5"

    [profiles.worker]
    name = "Worker"
    """)

    config = Config.load()

    assert config.agents["default"].model == "openai:gpt-5"
    assert config.agents["worker"].model == nil
  end

  test "runtime and profiles are the canonical config sections", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [defaults]
    model = "anthropic:some-model"

    [runtime]
    theme = "runtime-theme"

    [profiles.default]
    name = "Runtime Profile"
    model = "openai:new-profile-model"
    """)

    config = Config.load()

    assert config.agent.default_model == "anthropic:some-model"
    assert config.agent.theme == "runtime-theme"
    assert config.agents["default"].name == "Runtime Profile"
    assert config.agents["default"].model == "openai:new-profile-model"
  end

  test "deprecated [agent] section raises ValidationError", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agent]
    default_model = "anthropic:legacy-model"
    """)

    assert_raise LemonCore.Config.ValidationError, ~r/deprecated/i, fn ->
      Config.load()
    end
  end

  test "deprecated [agents] section raises ValidationError", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [agents.default]
    name = "Legacy Profile"
    """)

    assert_raise LemonCore.Config.ValidationError, ~r/deprecated/i, fn ->
      Config.load()
    end
  end

  test "parses gateway binding agent_id", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [gateway]
    enable_stub = true

    [[gateway.bindings]]
    transport = "demo"
    chat_id = 123
    agent_id = "daily"
    """)

    config = Config.load()

    [binding] = config.gateway.bindings
    assert binding.transport == :demo
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

  test "parses web tool configuration under runtime.tools", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.tools.web.search]
    enabled = true
    provider = "perplexity"
    max_results = 7
    timeout_seconds = 42
    cache_ttl_minutes = 10

    [runtime.tools.web.search.failover]
    enabled = false
    provider = "brave"

    [runtime.tools.web.search.perplexity]
    api_key = "pplx-test"
    base_url = "https://api.perplexity.ai"
    model = "perplexity/sonar"

    [runtime.tools.web.fetch]
    enabled = true
    max_chars = 64000
    timeout_seconds = 25
    cache_ttl_minutes = 5
    max_redirects = 2
    readability = false
    allow_private_network = false
    allowed_hostnames = ["example.com"]

    [runtime.tools.web.fetch.firecrawl]
    enabled = true
    api_key = "fc-test"
    base_url = "https://api.firecrawl.dev"
    only_main_content = true
    max_age_ms = 123000
    timeout_seconds = 15

    [runtime.tools.web.cache]
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

  test "parses wasm tool configuration under runtime.tools", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.tools.wasm]
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
    [runtime.tools.wasm]
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

  test "exposes tool disclosure defaults on agent.tools with no config" do
    config = Config.load()

    assert config.agent.tools.disclosure == %{
             enabled: true,
             budget_tokens: 40_000,
             catalog_tokens: 2_000,
             max_results: 5
           }
  end

  test "parses tool disclosure configuration under runtime.tools", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.tools.disclosure]
    enabled = false
    budget_tokens = 12000
    catalog_tokens = 500
    max_results = 3
    """)

    config = Config.load()

    assert config.agent.tools.disclosure == %{
             enabled: false,
             budget_tokens: 12_000,
             catalog_tokens: 500,
             max_results: 3
           }
  end

  test "env overrides tool disclosure configuration", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.tools.disclosure]
    enabled = true
    budget_tokens = 12000
    """)

    System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "false")
    System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "9999")

    config = Config.load()

    assert config.agent.tools.disclosure.enabled == false
    assert config.agent.tools.disclosure.budget_tokens == 9_999
  after
    System.delete_env("LEMON_TOOL_DISCLOSURE_ENABLED")
    System.delete_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS")
  end

  test "tool disclosure env declarations are registered with their defaults" do
    # The switch defaults ON: the token budget is the real gate, and a catalog
    # under it is left untouched, so default-on costs nothing.
    assert LemonCore.Env.get(:lemon_tool_disclosure_enabled) == true
    assert LemonCore.Env.get(:lemon_tool_disclosure_budget_tokens) == 40_000
    assert LemonCore.Env.get(:lemon_tool_disclosure_catalog_tokens) == 2_000

    System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "123")
    System.put_env("LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS", "45")
    System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "false")

    assert LemonCore.Env.get(:lemon_tool_disclosure_budget_tokens) == 123
    assert LemonCore.Env.get(:lemon_tool_disclosure_catalog_tokens) == 45
    assert LemonCore.Env.get(:lemon_tool_disclosure_enabled) == false
  after
    System.delete_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS")
    System.delete_env("LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS")
    System.delete_env("LEMON_TOOL_DISCLOSURE_ENABLED")
  end

  test "project config deep-merges onto global for tool disclosure", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [runtime.tools.disclosure]
    budget_tokens = 12000
    catalog_tokens = 500
    """)

    project_dir = Path.join(home, "project")
    File.mkdir_p!(Path.join(project_dir, ".lemon"))

    File.write!(Path.join([project_dir, ".lemon", "config.toml"]), """
    [runtime.tools.disclosure]
    catalog_tokens = 750
    max_results = 2
    """)

    config = Config.load(project_dir)

    # The project file must not blow away the sibling keys the global file set.
    assert config.agent.tools.disclosure == %{
             enabled: true,
             budget_tokens: 12_000,
             catalog_tokens: 750,
             max_results: 2
           }
  end

  test "the deprecated tool disclosure spellings hard-fail", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)
    config_path = Path.join(global_dir, "config.toml")

    for section <- ["agent.tools.disclosure", "tools.disclosure"] do
      File.write!(config_path, """
      [#{section}]
      budget_tokens = 12000
      """)

      assert_raise LemonCore.Config.ValidationError, fn -> Config.load() end
    end
  end

  test "tool disclosure declarations are shaped like the rest of the registry" do
    declarations = LemonCore.Env.by_area(:tools_disclosure)

    assert Enum.map(declarations, & &1.env_var) == [
             "LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS",
             "LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS",
             "LEMON_TOOL_DISCLOSURE_ENABLED"
           ]

    for declaration <- declarations do
      assert declaration.aliases == []
      assert declaration.secret? == false
      assert declaration.required? == false
      assert declaration.apps == [:lemon_core]
      assert declaration.doc != ""
      assert String.starts_with?(declaration.env_var, "LEMON_")
    end

    assert LemonCore.Env.describe(:lemon_tool_disclosure_budget_tokens).type == :integer
    assert LemonCore.Env.describe(:lemon_tool_disclosure_catalog_tokens).type == :integer
    assert LemonCore.Env.describe(:lemon_tool_disclosure_enabled).type == :boolean
  end

  test "tool disclosure env vars are documented in the config registry reference" do
    # `LemonCore.Env.Declarations` renders docs/config-registry.md, so a new
    # declaration that never reaches the table is an undocumented knob.
    case find_upwards("docs/config-registry.md") do
      nil ->
        # Running outside the umbrella checkout (e.g. a packaged build).
        :ok

      path ->
        doc = File.read!(path)

        for declaration <- LemonCore.Env.by_area(:tools_disclosure) do
          assert doc =~ "`#{declaration.env_var}`",
                 "#{declaration.env_var} is declared but missing from docs/config-registry.md"

          assert doc =~ declaration.doc,
                 "#{declaration.env_var}'s description in docs/config-registry.md has drifted"
        end
    end
  end

  test "tool disclosure defaults agree between the registry and the config resolver" do
    resolved = Config.load().agent.tools.disclosure

    assert LemonCore.Env.describe(:lemon_tool_disclosure_enabled).default == resolved.enabled

    assert LemonCore.Env.describe(:lemon_tool_disclosure_budget_tokens).default ==
             resolved.budget_tokens

    assert LemonCore.Env.describe(:lemon_tool_disclosure_catalog_tokens).default ==
             resolved.catalog_tokens
  end

  test "flattens registered channel sections onto the legacy gateway map", %{home: home} do
    global_dir = Path.join(home, ".lemon")
    File.mkdir_p!(global_dir)

    File.write!(Path.join(global_dir, "config.toml"), """
    [gateway]
    enable_stub = true

    [gateway.stub]
    default_account_id = "demo-work"
    default_chat_id = -100123
    """)

    config = Config.load()

    assert config.gateway[:enable_stub] == true

    assert config.gateway[:stub] == %{
             resolved: true,
             raw: %{"default_account_id" => "demo-work", "default_chat_id" => -100_123}
           }
  end

  # Tests may run from the umbrella root or from apps/lemon_core, so locate
  # repo-relative documentation by walking up from the current directory.
  defp find_upwards(relative_path) do
    File.cwd!()
    |> Path.expand()
    |> Stream.unfold(fn
      "/" -> nil
      dir -> {dir, Path.dirname(dir)}
    end)
    |> Enum.find_value(fn dir ->
      candidate = Path.join(dir, relative_path)
      if File.regular?(candidate), do: candidate
    end)
  end
end
