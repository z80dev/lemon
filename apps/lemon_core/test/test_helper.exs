exclude_tags =
  if "--cover" in System.argv() do
    [:memory_perf, :smoke, :reload, :external]
  else
    [:memory_perf, :smoke, :external]
  end

ExUnit.start(exclude: exclude_tags)

# Compile and load support files
Code.require_file("support/http_stub.ex", __DIR__)
