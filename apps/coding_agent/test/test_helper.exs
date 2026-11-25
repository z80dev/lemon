# The first exec of `node` on a fresh CI runner pages its binary in from a
# cold disk: measured 0.1-4.1 s across GitHub-hosted runners, ~20 ms after.
# Execution-node inspection runs its Node helper under a 2 s deadline, so load
# the binary once before tests race that one-time cost.
if node = System.find_executable("node"), do: System.cmd(node, ["-e", "0"])

ast_grep_opts =
  case System.get_env("LEMON_AST_GREP_EXECUTABLE") do
    nil -> []
    executable -> [ast_grep_executable: executable]
  end

exclude_tags =
  case CodingAgent.Tools.AstGrep.availability(File.cwd!(), ast_grep_opts) do
    {:ok, _} -> [:integration]
    {:error, _} -> [:integration, :ast_grep]
  end

defmodule CodingAgent.TestPdfPython do
  @moduledoc false
  # Operator-selected Python with a real PDF library: LEMON_PDF_PYTHON, else PATH python3.
  def executable do
    System.get_env("LEMON_PDF_PYTHON") || System.find_executable("python3")
  end

  def available? do
    case executable() do
      nil ->
        false

      python ->
        probe =
          "import importlib.util as u, sys; sys.exit(0 if u.find_spec('pypdf') or u.find_spec('fitz') else 1)"

        match?({_, 0}, System.cmd(python, ["-I", "-c", probe], stderr_to_stdout: true))
    end
  end
end

exclude_tags =
  if CodingAgent.TestPdfPython.available?(),
    do: exclude_tags,
    else: [:pdf_python_library | exclude_tags]

exclude_tags =
  if System.find_executable("python3"), do: exclude_tags, else: [:python3 | exclude_tags]

exclude_tags =
  if System.find_executable("deno"), do: exclude_tags, else: [:deno | exclude_tags]

exclude_tags =
  if System.find_executable("rsvg-convert"),
    do: exclude_tags,
    else: [:rsvg_convert | exclude_tags]

exclude_tags =
  if :os.type() == {:unix, :darwin}, do: exclude_tags, else: [:apfs_clone | exclude_tags]

Code.require_file("support/host_capabilities.ex", __DIR__)

exclude_tags =
  case CodingAgent.TestHostCapabilities.lldb_launch() do
    :ok ->
      exclude_tags

    {:error, reason} ->
      IO.puts(:stderr, "Excluding :lldb_dap: host launch capability unavailable (#{reason})")
      [:lldb_dap | exclude_tags]
  end

# CI builds the browser driver and sets LEMON_TEST_REQUIRE_BROWSER_DRIVER=1, so
# a missing prerequisite there fails the run instead of excluding the smoke.
exclude_tags =
  case CodingAgent.TestHostCapabilities.browser_driver() do
    :ok ->
      exclude_tags

    {:error, reason} ->
      if System.get_env("LEMON_TEST_REQUIRE_BROWSER_DRIVER") == "1" do
        raise "LEMON_TEST_REQUIRE_BROWSER_DRIVER=1 but the :browser_driver smoke is unavailable (#{reason})"
      end

      IO.puts(:stderr, "Excluding :browser_driver: #{reason}")
      [:browser_driver | exclude_tags]
  end

ExUnit.configure(exclude: exclude_tags)
ExUnit.start(capture_log: true)

# Ensure consolidated protocol directory exists when using a custom build path
if build_path = System.get_env("MIX_BUILD_PATH") do
  File.mkdir_p!(Path.join(build_path, "consolidated"))
end

# Ensure agent directories exist under the isolated HOME
CodingAgent.Config.ensure_dirs!()

# Skills are now managed by lemon_skills (registry + installer).
Application.ensure_all_started(:lemon_skills)

{:ok, _} = Application.ensure_all_started(:coding_agent)

# Compile test support files
Code.require_file("support/permission_helpers.ex", __DIR__)
Code.require_file("support/test_git_repo.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)
Code.require_file("support/session_cleanup.ex", __DIR__)
Code.require_file("support/tool_intent_recorder.ex", __DIR__)
Code.require_file("support/task_runtime_helpers.ex", __DIR__)

# Load shared test support from the lemon_agent and lemon_ai apps. These are
# required unconditionally on purpose: an `if File.exists?` guard turns a moved
# or renamed support file into dozens of confusing UndefinedFunctionError
# failures inside individual tests, whereas a hard require fails once, here,
# with the path that no longer resolves.
Code.require_file(Path.join([__DIR__, "..", "..", "lemon_agent", "test", "support", "mocks.ex"]))

Code.require_file(
  Path.join([__DIR__, "..", "..", "lemon_ai", "test", "support", "integration_config.ex"])
)
