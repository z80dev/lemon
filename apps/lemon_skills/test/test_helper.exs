ExUnit.start(exclude: [:integration])

# Isolate HOME so lemon_skills tests don't touch user-level skills/config.
home =
  Path.join(
    System.tmp_dir!(),
    "lemon_skills_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

# Keep X adapter resolution deterministic in tests; individual tests can override.
Application.put_env(:lemon_channels, :x_api_use_secrets, false)

Application.ensure_all_started(:lemon_skills)
