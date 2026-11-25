ExUnit.start(exclude: [:integration], capture_log: true)

Code.require_file("../../lemon_platform_test/test_support.exs", __DIR__)

# Isolate HOME so lemon_skills tests don't touch user-level skills/config.
home =
  Path.join(
    System.tmp_dir!(),
    "lemon_skills_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

# Load test support modules
Code.require_file("support/http_mock.ex", __DIR__)
Code.require_file("support/test_git_repo.ex", __DIR__)
Code.require_file("support/fake_ssh.ex", __DIR__)
Code.require_file("support/learning_nudge_config.ex", __DIR__)
Code.require_file("support/mcp_fixture_server.ex", __DIR__)
Code.require_file("support/session_cleanup.ex", __DIR__)

# Wire up the deterministic HTTP mock so Discovery tests don't need real HTTP.
Application.put_env(:lemon_skills, :http_client, LemonSkills.HttpClient.Mock)

Application.ensure_all_started(:lemon_skills)
