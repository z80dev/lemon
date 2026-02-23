ExUnit.configure(exclude: [:integration])
ExUnit.start()

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

# Skills are now managed by lemon_skills (registry + installer).
Application.ensure_all_started(:lemon_skills)

# Compile test support files
Code.require_file("support/mock_ui.ex", __DIR__)
Code.require_file("support/permission_helpers.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)

# Load shared test support from agent_core app
agent_core_support = Path.join([__DIR__, "..", "..", "agent_core", "test", "support", "mocks.ex"])

if File.exists?(agent_core_support) do
  Code.require_file(agent_core_support)
end

# Load shared test support from ai app (for integration tests)
ai_support = Path.join([__DIR__, "..", "..", "ai", "test", "support", "integration_config.ex"])

if File.exists?(ai_support) do
  Code.require_file(ai_support)
end
