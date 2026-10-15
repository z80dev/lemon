ast_grep_opts =
  case System.get_env("LEMON_AST_GREP_EXECUTABLE") do
    nil -> []
    executable -> [ast_grep_executable: executable]
  end

exclude_tags =
  case CodingAgent.Tools.AstGrep.availability(ast_grep_opts) do
    {:ok, _} -> [:integration]
    {:error, _} -> [:integration, :ast_grep]
  end

exclude_tags =
  if System.find_executable("python3"), do: exclude_tags, else: [:python3 | exclude_tags]

exclude_tags =
  case {
    CodingAgent.Debug.Adapters.select_launch("/x/a.c", "/", "lldb-dap", :file),
    System.find_executable("clang") || System.find_executable("cc")
  } do
    {{:ok, _}, compiler} when is_binary(compiler) -> exclude_tags
    _ -> [:lldb_dap | exclude_tags]
  end

ExUnit.configure(exclude: exclude_tags)
ExUnit.start(capture_log: true)

# Use a test-local store backend so coding_agent tests don't depend on lemon_gateway.
Code.require_file("support/test_store.ex", __DIR__)
Application.put_env(:lemon_core, :store_mod, CodingAgent.TestStore)

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Isolate HOME to avoid leaking user-level config (CLAUDE.md, config.toml, extensions)
original_home = System.get_env("HOME")

home =
  Path.join(
    System.tmp_dir!(),
    "coding_agent_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

# Keep rustup/cargo toolchain paths stable after HOME isolation so tests that call
# cargo via rustup shims can still resolve installed toolchains and targets.
if original_home do
  if is_nil(System.get_env("RUSTUP_HOME")) do
    System.put_env("RUSTUP_HOME", Path.join(original_home, ".rustup"))
  end

  if is_nil(System.get_env("CARGO_HOME")) do
    System.put_env("CARGO_HOME", Path.join(original_home, ".cargo"))
  end
end

# Ensure agent directories exist under the isolated HOME
CodingAgent.Config.ensure_dirs!()

# Ordinary session fixtures mock the agent stream, not project-fact extraction.
# Keep their completed turns/compactions from starting unrelated provider jobs.
# Memory tests opt in through their project config and control extraction themselves.
config_path = LemonCore.Config.Modular.global_path()
File.mkdir_p!(Path.dirname(config_path))
File.write!(config_path, "[features]\nsession_search = \"off\"\n")

# Skills are now managed by lemon_skills (registry + installer).
Application.ensure_all_started(:lemon_skills)

# Earlier app suites in the same umbrella run may have stopped :coding_agent
# (e.g. lemon_router's baseline reset); suite order no longer guarantees a
# restart, so establish our own baseline.
{:ok, _} = Application.ensure_all_started(:coding_agent)

# Compile test support files
Code.require_file("support/controlled_coordinator_session.ex", __DIR__)
Code.require_file("support/permission_helpers.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)

# Load shared test support from the lemon_agent and lemon_ai apps. These are
# required unconditionally on purpose: an `if File.exists?` guard turns a moved
# or renamed support file into dozens of confusing UndefinedFunctionError
# failures inside individual tests, whereas a hard require fails once, here,
# with the path that no longer resolves.
Code.require_file(Path.join([__DIR__, "..", "..", "lemon_agent", "test", "support", "mocks.ex"]))

Code.require_file(
  Path.join([__DIR__, "..", "..", "lemon_ai", "test", "support", "integration_config.ex"])
)
