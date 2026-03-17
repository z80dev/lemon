defmodule LemonCore.Runtime.BootTest do
  use ExUnit.Case, async: false

  alias LemonCore.Runtime.{Boot, Env}

  @base_env %Env{
    control_port: 19_980,
    web_port: 19_981,
    sim_port: 19_982,
    dotenv_dir: nil
  }

  describe "start/2 — halt safety" do
    test "returns error tuple rather than calling System.halt when an app fails to start" do
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
      System.put_env("MIX_ENV", "prod")
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
      System.delete_env("LEMON_GATEWAY_COOKIE")

      env = %Env{control_port: 19_989, web_port: 19_990, sim_port: 19_991, dotenv_dir: nil}

      assert_raise RuntimeError, ~r/production.*cookie/i, fn ->
        Boot.start(:runtime_min, env: env, check_running: false)
      end
    after
      System.delete_env("MIX_ENV")
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
      System.delete_env("LEMON_GATEWAY_COOKIE")
    end
  end
end
