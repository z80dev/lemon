ExUnit.start(capture_log: true)

unless System.get_env("LEMON_TEST_ALLOW_LIVE_CREDENTIALS") == "1" do
  ExUnit.configure(exclude: [:automation_live])
end
