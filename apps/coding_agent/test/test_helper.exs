ExUnit.start()

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Isolate HOME to avoid leaking user-level config (CLAUDE.md, settings.json, extensions)
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
