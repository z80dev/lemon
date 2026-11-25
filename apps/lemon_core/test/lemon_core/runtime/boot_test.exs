defmodule LemonCore.Runtime.BootTest do
  use ExUnit.Case, async: false

  alias LemonCore.Runtime.{Boot, Env}
  alias LemonPlatformTest.Testing.HermeticEnv

  @base_env %Env{
    control_port: 19_980,
    web_port: 19_981,
    dotenv_dir: nil
  }

  describe "start/2 — halt safety" do
    test "returns error tuple rather than calling System.halt when an app fails to start" do
      app_keys =
        [
          {:lemon_control_plane, :port}
          | Enum.map(Env.runtime_endpoints(), fn {_, app, key} ->
              {app, key}
            end)
        ]

      original_env =
        for {app, key} <- app_keys, do: {app, key, Application.fetch_env(app, key)}

      on_exit(fn ->
        Enum.each(original_env, fn
          {app, key, {:ok, value}} -> Application.put_env(app, key, value)
          {app, key, :error} -> Application.delete_env(app, key)
        end)
      end)

      # Boot.start(:runtime_min) tries to start gateway/router/channels/control_plane.
      # In the test environment those apps may not be fully startable.
      # The critical invariant: if a start failure occurs, Boot must return
      # {:error, {app, reason}} rather than calling System.halt(1).
      # We verify this by asserting the return type: if System.halt had been
      # called, this test process would be terminated and the assertion below
      # would never execute.
      result = Boot.start(:runtime_min, env: @base_env, check_running: false)

      # The test reaching here already proves no System.halt was called.
      # Additionally verify the return value is a recognised shape.
      assert result == :ok or match?({:error, {_app, _reason}}, result),
             "Expected :ok or {:error, {app, reason}} but got: #{inspect(result)}"
    end
  end

  describe "start/2 — production cookie guard" do
    test "rejects boot in production context when node cookie is missing" do
      snapshot =
        HermeticEnv.snapshot_env(~w(MIX_ENV LEMON_GATEWAY_NODE_COOKIE LEMON_GATEWAY_COOKIE))

      on_exit(fn -> HermeticEnv.restore_env(snapshot) end)

      System.put_env("MIX_ENV", "prod")
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
      System.delete_env("LEMON_GATEWAY_COOKIE")

      env = %Env{control_port: 19_989, web_port: 19_990, dotenv_dir: nil}

      assert_raise RuntimeError, ~r/production.*cookie/i, fn ->
        Boot.start(:runtime_min, env: env, check_running: false)
      end
    end
  end
end
