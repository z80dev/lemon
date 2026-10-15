# The first exec of `node` on a fresh CI runner pages its binary in from a
# cold disk: measured 0.1-4.1 s across GitHub-hosted runners, ~20 ms after.
# Local-server tests spawn a Node driver under a 1 s request deadline, so load
# the binary once before they race that one-time cost.
if node = System.find_executable("node"), do: System.cmd(node, ["-e", "0"])

ExUnit.start(capture_log: true)
