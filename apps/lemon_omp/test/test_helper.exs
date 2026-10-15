ExUnit.start(capture_log: true)

unless System.get_env("LEMON_OMP_LIVE") == "1" do
  ExUnit.configure(exclude: [:omp_live])
end
