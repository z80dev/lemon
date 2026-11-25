exclude_tags =
  if "--cover" in System.argv() do
    [:memory_perf, :smoke, :reload, :external]
  else
    [:memory_perf, :smoke, :external]
  end

exclude_tags =
  if match?({:unix, :linux}, :os.type()), do: exclude_tags, else: [:linux_only | exclude_tags]

ExUnit.start(exclude: exclude_tags, capture_log: true)

Code.require_file("../../lemon_platform_test/test_support.exs", __DIR__)

# Compile and load support files
Code.require_file("support/http_stub.ex", __DIR__)
Code.require_file("support/session_cleanup.ex", __DIR__)
