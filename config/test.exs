import Config

# Tests must not depend on or mutate a developer's persistent state on disk.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.EtsBackend,
  backend_opts: []

# Avoid writing dets / sessions / global config under ~/.lemon/agent during tests.
config :coding_agent, :agent_dir,
  Path.join(System.tmp_dir!(), "lemon_agent_test_#{:erlang.unique_integer([:positive])}")
