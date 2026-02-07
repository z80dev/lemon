ExUnit.start()

# Isolate HOME so lemon_skills tests don't touch user-level skills/config.
home =
  Path.join(
    System.tmp_dir!(),
    "lemon_skills_test_home_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(home)
System.put_env("HOME", home)

Application.ensure_all_started(:lemon_skills)
