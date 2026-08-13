ExUnit.start()

# Isolate HOME so these tests (notably the moved LemonSkills.McpSource suite,
# which persists OAuth tokens through LemonCore.Secrets) never write into the
# developer's real `~/.lemon` state directory.
home =
  Path.join(
    System.tmp_dir!(),
    "lemon_mcp_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)
