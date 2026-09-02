ExUnit.configure(exclude: [:integration])
ExUnit.start()

# Use a test-local store backend so coding_agent tests don't depend on lemon_gateway.
Application.put_env(:lemon_core, :store_mod, CodingAgent.TestStore)

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Scope the user's home to a fresh directory so no test reads or writes the
# real ~/.lemon, ~/.claude or ~/.agents. Everything that resolves the home
# goes through LemonCore.Paths, which honours this override; the OS HOME is
# left alone, so nothing else in the VM (toolchains, other apps' suites) is
# affected.
home =
  Path.join(
    System.tmp_dir!(),
    "coding_agent_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
Application.put_env(:lemon_core, :paths, home_dir: home)

# Ensure agent directories exist under the scoped home
CodingAgent.Config.ensure_dirs!()

# Earlier app suites in the same umbrella run may have stopped :coding_agent
# (e.g. lemon_router's baseline reset); suite order no longer guarantees a
# restart, so establish our own baseline. lemon_skills starts with it.
{:ok, _} = Application.ensure_all_started(:coding_agent)

# Test support modules (CodingAgent.TestStore, CodingAgent.Test.MockUI,
# LemonAgent.Test.Mocks, LemonAi.Test.IntegrationConfig, ...) are compiled
# with their apps in the test environment; see elixirc_paths/1 in mix.exs.
