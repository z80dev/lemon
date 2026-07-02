ExUnit.configure(exclude: [:integration])
ExUnit.start()

Code.require_file(
  Path.join([__DIR__, "..", "..", "coding_agent", "test", "support", "test_store.ex"])
)

Application.put_env(:lemon_core, :store_mod, CodingAgent.TestStore)

if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

original_home = System.get_env("HOME")

home =
  Path.join(
    System.tmp_dir!(),
    "lemon_evals_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

if original_home do
  if is_nil(System.get_env("RUSTUP_HOME")) do
    System.put_env("RUSTUP_HOME", Path.join(original_home, ".rustup"))
  end

  if is_nil(System.get_env("CARGO_HOME")) do
    System.put_env("CARGO_HOME", Path.join(original_home, ".cargo"))
  end
end

CodingAgent.Config.ensure_dirs!()
Application.ensure_all_started(:lemon_skills)
{:ok, _} = Application.ensure_all_started(:coding_agent)
