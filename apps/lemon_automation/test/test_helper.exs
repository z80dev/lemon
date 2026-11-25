ExUnit.start(capture_log: true)

Code.require_file("../../lemon_platform_test/test_support.exs", __DIR__)

unless System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") == "1" do
  ExUnit.configure(exclude: [:automation_live])
end
