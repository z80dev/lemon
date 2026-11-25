defmodule LemonGateway.Test.AppIsolation do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  def isolate_gateway(keys, opts \\ []) do
    # ExUnit runs these in reverse registration order: verify after restoration.
    on_exit(fn ->
      assert List.keymember?(Application.started_applications(), :lemon_gateway, 0)
    end)

    env = [
      app_env: Enum.map(keys, &{:lemon_gateway, &1}),
      system_env: Keyword.get(opts, :system_env, [])
    ]

    LemonPlatformTest.AppRestart.setup_app_restart([:lemon_gateway], env)
  end
end
