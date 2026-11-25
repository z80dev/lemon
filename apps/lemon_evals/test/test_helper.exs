# `:slow` boots the offline native runtime for the latency lane; nightly's
# latency job includes it (`--include slow`).
excluded =
  if :os.type() == {:unix, :darwin},
    do: [:slow],
    else: [:slow, :darwin_only]

ExUnit.configure(exclude: excluded)

ExUnit.start(capture_log: true)

if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

CodingAgent.Config.ensure_dirs!()
Application.ensure_all_started(:lemon_skills)
{:ok, _} = Application.ensure_all_started(:coding_agent)
