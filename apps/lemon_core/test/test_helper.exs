exclude_tags =
  if "--cover" in System.argv() do
    [:memory_perf, :smoke, :reload]
  else
    [:memory_perf, :smoke]
  end

ExUnit.start(exclude: exclude_tags)
