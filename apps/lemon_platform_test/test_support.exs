# Load the same helper sources shipped by the kit. Sibling suites can use
# these without a Mix edge back to this leaf (which depends on those apps).
for {module, file} <- [
      {LemonPlatformTest.Testing, "testing.ex"},
      {LemonPlatformTest.Testing.AsyncHelpers, "testing/async_helpers.ex"},
      {LemonPlatformTest.Testing.FileServerTap, "testing/file_server_tap.ex"},
      {LemonPlatformTest.Testing.HermeticEnv, "testing/hermetic_env.ex"}
    ] do
  unless Code.ensure_loaded?(module) do
    Code.require_file("lib/lemon_platform_test/#{file}", __DIR__)
  end
end
