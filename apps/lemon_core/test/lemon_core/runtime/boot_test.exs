defmodule LemonCore.Runtime.BootTest do
  # async: false — tests set LEMON_FEATURE_PRODUCT_RUNTIME env var
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
      System.put_env("LEMON_FEATURE_PRODUCT_RUNTIME", "default-on")

      result = Boot.start(:runtime_min, env: @base_env, check_running: false)

      # The test reaching here already proves no System.halt was called.
      # Additionally verify the return value is a recognised shape.
      assert result == :ok or match?({:error, {_app, _reason}}, result),
             "Expected :ok or {:error, {app, reason}} but got: #{inspect(result)}"
    after
      System.delete_env("LEMON_FEATURE_PRODUCT_RUNTIME")
    end
  end

  describe "start/2 — product_runtime feature gate" do
    test "returns {:error, {:feature_disabled, :product_runtime}} when flag is off" do
      # Regression test: Boot.start/2 must check the product_runtime feature gate
      # before starting any applications. When the flag is :off the boot must
      # return a structured error rather than starting the runtime silently.
      System.put_env("LEMON_FEATURE_PRODUCT_RUNTIME", "off")
      env = %Env{control_port: 19_983, web_port: 19_984, sim_port: 19_985, dotenv_dir: nil}

      result = Boot.start(:runtime_min, env: env, check_running: false)

      assert result == {:error, {:feature_disabled, :product_runtime}},
             "Expected feature gate to block boot, got: #{inspect(result)}"
    after
      System.delete_env("LEMON_FEATURE_PRODUCT_RUNTIME")
    end

    test "proceeds when product_runtime is default-on" do
      System.put_env("LEMON_FEATURE_PRODUCT_RUNTIME", "default-on")
      env = %Env{control_port: 19_986, web_port: 19_987, sim_port: 19_988, dotenv_dir: nil}

      result = Boot.start(:runtime_min, env: env, check_running: false)

      # Should not return feature_disabled — any other outcome (ok or app error) is fine
      refute result == {:error, {:feature_disabled, :product_runtime}},
             "Boot should not be blocked when product_runtime is default-on"
    after
      System.delete_env("LEMON_FEATURE_PRODUCT_RUNTIME")
    end
  end
end
