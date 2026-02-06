ExUnit.configure(exclude: [:integration])
ExUnit.start()

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Isolate HOME to avoid leaking user-level config (CLAUDE.md, config.toml, extensions)
home =
  Path.join(
    System.tmp_dir!(),
    "coding_agent_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

# Ensure agent directories exist under the isolated HOME
CodingAgent.Config.ensure_dirs!()

# Compile test support files
Code.require_file("support/mock_ui.ex", __DIR__)

# Load shared test support from agent_core app
agent_core_support = Path.join([__DIR__, "..", "..", "agent_core", "test", "support", "mocks.ex"])

if File.exists?(agent_core_support) do
  Code.compile_file(agent_core_support)
end

# Load shared test support from ai app (for integration tests)
ai_support = Path.join([__DIR__, "..", "..", "ai", "test", "support", "integration_config.ex"])

if File.exists?(ai_support) do
  Code.compile_file(ai_support)
end
