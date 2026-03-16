defmodule LemonCore.Runtime.EnvTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Env

  describe "resolve/0" do
    test "returns default ports when env vars are unset" do
      clear_env(["LEMON_CONTROL_PLANE_PORT", "LEMON_WEB_PORT", "LEMON_SIM_UI_PORT"])

      env = Env.resolve()

      assert env.control_port == 4040
      assert env.web_port == 4080
      assert env.sim_port == 4090
    end

    test "reads ports from environment variables" do
      System.put_env("LEMON_CONTROL_PLANE_PORT", "5050")
      System.put_env("LEMON_WEB_PORT", "5080")
      System.put_env("LEMON_SIM_UI_PORT", "5090")

      env = Env.resolve()

      assert env.control_port == 5050
      assert env.web_port == 5080
      assert env.sim_port == 5090
    after
      clear_env(["LEMON_CONTROL_PLANE_PORT", "LEMON_WEB_PORT", "LEMON_SIM_UI_PORT"])
    end

    test "falls back to defaults for malformed port values" do
      System.put_env("LEMON_CONTROL_PLANE_PORT", "not_a_port")

      env = Env.resolve()

      assert env.control_port == 4040
    after
      System.delete_env("LEMON_CONTROL_PLANE_PORT")
    end
  end

  describe "debug?/0" do
    test "returns false when debug vars are absent" do
      clear_env(["LEMON_DEBUG", "LEMON_LOG_LEVEL"])
      refute Env.debug?()
    end

    test "returns true when LEMON_DEBUG=1" do
      System.put_env("LEMON_DEBUG", "1")
      assert Env.debug?()
    after
      System.delete_env("LEMON_DEBUG")
    end

    test "returns true when LEMON_LOG_LEVEL=debug" do
      System.put_env("LEMON_LOG_LEVEL", "debug")
      assert Env.debug?()
    after
      System.delete_env("LEMON_LOG_LEVEL")
    end
  end

  describe "node_name/0" do
    test "returns default when env var is unset" do
      System.delete_env("LEMON_GATEWAY_NODE_NAME")
      assert Env.node_name() == "lemon"
    end

    test "reads from LEMON_GATEWAY_NODE_NAME" do
      System.put_env("LEMON_GATEWAY_NODE_NAME", "mynode")
      assert Env.node_name() == "mynode"
    after
      System.delete_env("LEMON_GATEWAY_NODE_NAME")
    end
  end

  describe "node_cookie/0" do
    test "returns default when env vars are unset" do
      clear_env(["LEMON_GATEWAY_NODE_COOKIE", "LEMON_GATEWAY_COOKIE"])
      assert Env.node_cookie() == "lemon_gateway_dev_cookie"
    end

    test "reads from LEMON_GATEWAY_NODE_COOKIE" do
      System.put_env("LEMON_GATEWAY_NODE_COOKIE", "mysecret")
      assert Env.node_cookie() == "mysecret"
    after
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
    end
  end

  defp clear_env(keys) do
    Enum.each(keys, &System.delete_env/1)
  end
end
